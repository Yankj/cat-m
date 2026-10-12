#!/usr/bin/env python3
"""Check AF-1 goal closure, work-unit ownership, dependency graphs and local links.

This validates the planning contract only; it never reads or writes product results.
Uses only the Python standard library.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'docs/planning/AF-1'
contract = json.loads((BASE / 'contract.json').read_text())
canonical = json.loads((BASE / contract['authorities']['acceptance']).read_text())
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
assert not goals['AF-G0']['closes_full_acceptance_cases'], 'baseline preparation must not close release cases'
for item in scenarios.values():
    assert (BASE / item['procedure']).is_file(), item['id']
    assert item['id'] in (BASE / item['procedure']).read_text(), item['id']
for item in contract['extensions']:
    assert not item['required_for_AF_G5'] and item['activation'], item['id']
    assert set(item.get('acceptance_ids', [])) <= cases.keys(), item['id']

rules = contract['release_rules']
assert rules['same_release_manifest'] and rules['all_required_cases'] and rules['all_required_scenarios']
assert not rules['missing_evidence_is_pass'] and not rules['synthetic_can_replace_real_evidence']
assert rules['unchanged_provider_route_first'] and not rules['unknown_may_auto_replay']
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
print(f'PASS AF-1-G1 planning: {len(goals)} goals, {len(units)} work units, '
      f'{len(required)} required cases, {len(scenarios)} scenarios; DAG/ownership/links valid')
print('LIMIT planning integrity only; no product, model, database, deployment or device acceptance executed')
