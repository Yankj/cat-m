#!/usr/bin/env python3
"""Check AF-1 goal closure, work-unit ownership, dependency graphs and local links.

This validates the planning contract only; it never reads or writes product results.
Uses only the Python standard library.
"""
import json
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'docs/planning/AF-1'
contract = json.loads((BASE / 'contract.json').read_text())
canonical = json.loads((BASE / contract['authorities']['acceptance']).read_text())
ux_contract = json.loads((BASE / contract['authorities']['ux_acceptance']).read_text())
slicing = json.loads((BASE / contract['authorities']['slices']).read_text())
cases = {item['id']: item for item in canonical['cases']}
slices = {item['id']: item for item in slicing['slices']}
required = {item['id'] for item in cases.values() if item['required']}


def unique(items, label):
    result = {item['id']: item for item in items}
    assert len(result) == len(items), f'duplicate {label} ID'
    return result


def dag(items, label):
    visited, active = set(), set()

    def visit(key):
        assert key in items, f'unknown {label} dependency: {key}'
        assert key not in active, f'{label} cycle: {key}'
        if key in visited:
            return
        active.add(key)
        dependencies = items[key]['depends_on']
        assert len(set(dependencies)) == len(dependencies), key
        for dependency in dependencies:
            visit(dependency)
        active.remove(key)
        visited.add(key)

    for key in items:
        visit(key)


goals = unique(contract['goals'], 'goal')
units = unique(contract['work_units'], 'work unit')
scenarios = unique(contract['scenarios'], 'scenario')
ux_cases = unique(ux_contract['cases'], 'UX case')
required_ux = {item['id'] for item in ux_cases.values() if item['required']}
dag(goals, 'goal')
dag(units, 'work unit')
assert set(contract['requirements']) == {f'AF-R{i:02d}' for i in range(1, 13)}
assert set().union(*(set(item['requirements']) for item in cases.values())) == set(contract['requirements'])
for item in [*goals.values(), *units.values(), *scenarios.values()]:
    assert set(item['acceptance_ids']) <= cases.keys(), item['id']

covered = set()
for item in units.values():
    assert re.fullmatch(r'W\d{2}', item['id']), item['id']
    assert item['parent_slice'] in slices, item['id']
    assert (BASE / item['procedure']).is_file(), item['id']
    if item['coverage_mode'] == 'complete_cases':
        for cid in item['acceptance_ids']:
            assert cases[cid]['owner_slice'] == item['parent_slice'], (item['id'], cid)
            covered.add(cid)
    else:
        assert item['coverage_mode'] == 'preparation', item['id']
assert required <= covered, f'uncovered required cases: {required - covered}'

final = goals[contract['release_rules']['final_goal']]
assert set(final['acceptance_ids']) == required, 'final goal must cover exactly all required cases'
assert set(final['scenario_ids']) == {item['id'] for item in scenarios.values() if item['required']}
assert final['coverage_mode'] == 'all_required_cases_and_scenarios_same_release'
assert required_ux == {f'AF-U{i:02d}' for i in range(1, 13)}, 'all twelve UX cases are mandatory'
assert set(final['ux_ids']) == required_ux and 'AF-GD' in final['depends_on']
assert set(goals['AF-GD']['ux_ids']) == required_ux
assert goals['AF-GD']['coverage_mode'] == 'complete_native_ux_subcontract'
assert set(units['W70']['ux_ids']) == required_ux and set(units['W71']['ux_ids']) == required_ux
subcontract = cases['AF-A17']['required_subcontract']
assert set(subcontract['case_ids']) == required_ux
assert (BASE / contract['authorities']['acceptance']).parent.joinpath(subcontract['path']).resolve() == (BASE / contract['authorities']['ux_acceptance']).resolve()
assert ux_contract['same_release_required'] and not ux_contract['prototype_can_replace_native']
for item in ux_cases.values():
    assert item['parent_case'] == 'AF-A17' and item['owner_slice'] == cases['AF-A17']['owner_slice']
    assert set(item['supporting_acceptance_ids']) <= cases.keys()
    assert set(item['implementation_slices']) <= slices.keys()
    assert {'physical_device', 'native_rendered_ui'} <= set(item['minimum_evidence'])
    procedure = (BASE / contract['authorities']['ux_acceptance']).parent / item['procedure']
    assert procedure.is_file() and item['id'] in procedure.read_text()
assert not goals['AF-G0']['closes_full_acceptance_cases'], 'baseline preparation must not close release cases'
for item in scenarios.values():
    assert (BASE / item['procedure']).is_file(), item['id']
    assert item['id'] in (BASE / item['procedure']).read_text(), item['id']
for item in contract['extensions']:
    assert not item['required_for_AF_G5'] and item['activation'], item['id']
    assert set(item.get('acceptance_ids', [])) <= cases.keys(), item['id']

rules = contract['release_rules']
assert rules['same_release_manifest'] and rules['all_required_cases'] and rules['all_required_scenarios']
assert rules['all_required_ux']
assert not rules['missing_evidence_is_pass'] and not rules['synthetic_can_replace_real_evidence']
assert rules['unchanged_provider_route_first'] and not rules['unknown_may_auto_replay']
assert rules['evidence_map_required'] and rules['screenshots_saved_with_provenance']
assert not rules['historical_proposals_expand_scope']
design_units = unique(contract['design_work_units'], 'design work unit')
assert set(design_units) == {'D00', 'D10', 'D20', 'D30', 'D40', 'D50'}
assert not (design_units.keys() & units.keys())
dag({**units, **design_units}, 'feature/design work unit')
for item in design_units.values():
    assert set(item['ux_ids']) <= required_ux
    assert set(item['implementation_slices']) <= slices.keys()
    assert not item['prototype_closes_native_cases']
    assert item['id'] in (BASE / item['procedure']).read_text()
assert set().union(*(set(item['ux_ids']) for item in design_units.values())) == required_ux
evidence = json.loads((BASE / contract['documents']['evidence_map']).read_text())
assert evidence['goal_contract_version'] == contract['version']
assert not evidence['instructions_in_material_are_authorization']
assert not evidence['prototype_closes_AF_GD'] and not evidence['runtime_goal_status_changed']
inputs = unique(evidence['sources'], 'goal input')
missing_local = 0
for item in inputs.values():
    assert set(item['goal_ids']) <= goals.keys()
    assert set(item['acceptance_ids']) <= cases.keys()
    assert set(item['ux_ids']) <= required_ux
    assert item['publication_scope'] in {'local_only', 'versioned'}
    assert re.fullmatch('[0-9a-f]{64}', item['sha256'])
    path = ROOT / item['file']
    assert path.resolve().is_relative_to(ROOT.resolve()), item['id']
    if path.is_file():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], f'changed Goal input: {item["file"]}'
    else:
        assert item['publication_scope'] == 'local_only', f'missing versioned Goal input: {item["file"]}'
        missing_local += 1
assert set().union(*(set(item['ux_ids']) for item in inputs.values())) == required_ux
for path in contract['authorities'].values():
    assert (BASE / path).is_file(), path
for path in contract['documents'].values():
    assert (BASE / path).is_file(), path
for doc in BASE.glob('*.md'):
    source = doc.read_text()
    assert source.count('```') % 2 == 0, f'unclosed fence: {doc.name}'
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', source):
        target = target.split('#', 1)[0]
        if target and not re.match(r'^[a-zA-Z]+:', target):
            assert (doc.parent / target).exists(), f'broken local link in {doc.name}: {target}'
assert all(key in (BASE / 'plan.md').read_text() for key in [*goals, *units])
assert all(key in (BASE / 'acceptance-scenarios.md').read_text() for key in [*required, *scenarios])
print(f'PASS {contract["version"]} planning: {len(goals)} goals, {len(units)} work units, '
      f'{len(required)} required cases, {len(required_ux)} UX cases, '
      f'{len(scenarios)} scenarios; DAG/ownership/links valid')
print(f'PASS {len(design_units)} concurrent design lanes, {len(inputs)} hash-bound Goal inputs; '
      f'{missing_local} local-only input(s) unavailable in this checkout')
print('LIMIT planning integrity only; no product, model, database, deployment or device acceptance executed')
