#!/usr/bin/env python3
"""Validate CGUI-1's release contract, traceability and fixed truth fixtures.

Only static planning/source integrity is checked. This does not run a renderer,
model, database, physical device or any CopilotKit setup command.
"""
import hashlib
import json
import re
from decimal import Decimal, ROUND_HALF_EVEN
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'docs/acceptance'


def read(path):
    return json.loads(path.read_text())


def unique(items):
    result = {item['id']: item for item in items}
    assert len(result) == len(items), 'duplicate ID'
    return result


cg = read(BASE / 'conversation-generative-ui-acceptance.json')
final = read(BASE / 'catpaw-final-product-acceptance.json')
foundation = read(ROOT / 'docs/planning/AF-1/contract.json')
af = read(BASE / 'agent-foundation-acceptance.json')
ux = read(BASE / 'ios-codex-experience-acceptance.json')
cases = unique(cg['cases'])
expected = {f'CG-A{i:02d}' for i in range(1, 11)}
assert cg['schema_version'] == 1 and cg['version'] == 'CGUI-1'
assert set(cases) == expected
assert set(cg['required_for_goals']) == {'FINAL-G1', 'FINAL-G3'}
assert not cg['foundation_goal_replaced']
assert foundation['version'] == 'AF-1-G3-UX1'
assert len(final['foundation_required']['acceptance_ids']) == 18
assert len(final['foundation_required']['ux_ids']) == 12
assert len(final['foundation_required']['scenario_ids']) == 3
assert set(cg['domain_card_types']) == set(final['card_types']) == {
    'choice', 'form', 'plan', 'approval', 'artifact', 'comparison'
}
assert set(cg['presentation_types']) == {'table', 'chart', 'calculator'}
assert set(cg['chart_types']) == {'bar', 'line'}
assert set(cg['calculator_kernels']) == {'duration_budget_v1', 'weighted_comparison_v1'}
assert set(cg['action_classes']) == {'local_interaction', 'agent_followup', 'domain_command'}
assert cg['limits'] == {
    'payload_utf8_bytes': 65536, 'table_columns': 12, 'table_rows': 200,
    'cell_characters': 2000, 'chart_series': 4, 'points_per_series': 200,
    'source_references': 20, 'title_characters': 200, 'label_characters': 80,
    'finite_numbers_only': True
}
local = cg['local_interaction_rules']
for key in ['automatic_model_calls', 'automatic_network_requests', 'automatic_turns', 'automatic_domain_effects']:
    assert local[key] == 0, key
assert local['feedback_p95_ms'] == 150 and local['physical_local_samples_minimum'] >= 30

allowed = {
    'supporting_acceptance_ids': set(unique(af['cases'])),
    'ux_ids': set(unique(ux['cases'])),
    'quality_ids': set(unique(final['quality_checks'])),
    'work_units': set(unique(foundation['work_units'])),
    'design_units': set(unique(foundation['design_work_units'])),
    'scenario_ids': set(unique(foundation['scenarios']))
}
for case in cases.values():
    assert case['required'] and case['minimum_evidence'], case['id']
    for key, ids in allowed.items():
        actual = case.get(key, [])
        assert len(actual) == len(set(actual)) and set(actual) <= ids, (case['id'], key)
    assert case['work_units'] and case['design_units'], case['id']
for case_id in ['CG-A03', 'CG-A10']:
    assert {'physical_device', 'real_model', 'real_service'} <= set(cases[case_id]['minimum_evidence'])
assert 'persistent_intent' in cases['CG-A03']['minimum_evidence']
assert {'real_database', 'effect_receipt'} <= set(cases['CG-A05']['minimum_evidence'])
assert 'real_database' in cases['CG-A07']['minimum_evidence']
assert 'request_and_effect_counter_delta' in cases['CG-A04']['minimum_evidence']

# Recompute normative examples, independently of any proposed renderer.
duration = cg['truth_fixtures']['duration']
assert duration['unit'] == 'minutes' and duration['negative_remaining_visible']
for reserved, expected_remaining in [
    (duration['reserved'], duration['remaining']),
    (duration['second_reserved'], duration['second_remaining'])
]:
    result = Decimal(duration['total']) - Decimal(reserved) - Decimal(duration['step_count']) * Decimal(duration['per_step'])
    assert result == Decimal(expected_remaining), 'incorrect duration truth fixture'
weighted = cg['truth_fixtures']['weighted']
assert weighted['scores_are_synthetic_not_product_ranking']
for weights, expected_a, expected_b in [
    (weighted['weights'], weighted['result_a'], weighted['result_b']),
    (weighted['second_weights'], weighted['second_result_a'], weighted['second_result_b'])
]:
    denominator = sum(Decimal(str(w)) for w in weights)
    assert denominator > 0
    for scores, expected_result in [(weighted['scores_a'], expected_a), (weighted['scores_b'], expected_b)]:
        assert len(scores) == len(weights)
        actual = sum(Decimal(str(s)) * Decimal(str(w)) for s, w in zip(scores, weights)) / denominator
        assert actual.quantize(Decimal('0.01'), rounding=ROUND_HALF_EVEN) == Decimal(str(expected_result))

sub = final['conversation_ui_subcontract']
assert sub['version'] == cg['version'] and set(sub['case_ids']) == expected
assert set(sub['required_for_goals']) == set(cg['required_for_goals'])
assert not sub['foundation_goal_replaced']
assert (BASE / sub['path']).resolve() == (BASE / 'conversation-generative-ui-acceptance.json').resolve()
fq = unique(final['quality_checks'])['FQ-01']['required_subcontract']
assert fq['path'] == sub['path'] and set(fq['case_ids']) == expected
assert unique(final['goals'])['FINAL-G1']['required_subcontract_version'] == 'CGUI-1'
assert final['release_rules']['all_conversation_ui_cases_required']
meta = foundation['final_product_contract']['conversation_ui_subcontract']
assert meta['version'] == 'CGUI-1' and set(meta['required_case_ids']) == expected
assert set(meta['required_for_goals']) == {'FINAL-G1', 'FINAL-G3'} and not meta['foundation_goal_replaced']
rules = cg['release_rules']
for key in ['same_candidate_required', 'all_cases_required', 'all_cases_pass_before_FINAL_G1', 'at_least_one_real_model_native_followup_path']:
    assert rules[key], key
for key in ['synthetic_replaces_real_acceptance', 'frozen_http_overwritten', 'same_work_requires_same_sse_run',
            'local_ui_authorizes_writes', 'arbitrary_generated_code_required', 'copilotkit_sdk_or_intelligence_required',
            'onboarding_cli_executed', 'new_model_calls_or_installations_authorized_by_document']:
    assert not rules[key], key

manifest_path = ROOT / 'docs/research/copilotkit-conversation-ui-source-manifest-2026-10-13.json'
manifest = read(manifest_path)
upstream = manifest['upstream']
assert upstream['repository'] == 'CopilotKit/OpenIntelligentUI'
assert upstream['commit'] == '9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b'
assert upstream['main_ref_readback_matches_pin']
assert len(upstream['files']) == 6 and len({f['path'] for f in upstream['files']}) == 6
cached_sources = 0
for item in upstream['files']:
    assert re.fullmatch('[0-9a-f]{40}', item['blob_sha'])
    assert re.fullmatch('[0-9a-f]{64}', item['sha256']) and item['size'] > 0
    assert item['url'] == f'https://github.com/{upstream["repository"]}/blob/{upstream["commit"]}/{item["path"]}'
    cached = ROOT / 'build/research-copilotkit-20261013/OpenIntelligentUI' / item['path']
    if cached.is_file():
        data = cached.read_bytes()
        assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
        assert hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest() == item['blob_sha']
        cached_sources += 1
onboarding = manifest['onboarding']
assert onboarding['size'] == 2058 and re.fullmatch('[0-9a-f]{64}', onboarding['sha256'])
assert onboarding['contains_cli_instructions'] and onboarding['raw_cache_publication_scope'] == 'ignored_local_only'
for key in ['cli_executed', 'run_configuration_visible', 'intelligence_resources_or_pricing_verified']:
    assert not onboarding[key], key
for key in ['sdk_dependencies_installed', 'framework_compatibility_executed']:
    assert not manifest[key], key
cached = ROOT / 'build/research-onboarding-20261013/onboarding-page.html'
if cached.is_file():
    assert len(cached.read_bytes()) == onboarding['size']
    assert hashlib.sha256(cached.read_bytes()).hexdigest() == onboarding['sha256']

docs = [BASE / cg['spec_path'], BASE / cg['procedure_path'], manifest_path,
        ROOT / manifest['primary_reference_index'],
        ROOT / 'docs/planning/AF-1/development-start-contract.md',
        ROOT / 'docs/planning/AF-1/long-task-development-prompt.md']
assert (BASE / cg['result_authority']).resolve() == (ROOT / 'docs/status/master-plan.md').resolve()
for doc in docs:
    assert doc.is_file(), doc
    if doc.suffix != '.md':
        continue
    source = doc.read_text()
    assert source.count('```') % 2 == 0, f'unclosed fence: {doc}'
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', source):
        target = target.split('#', 1)[0]
        if target and not re.match(r'^[a-zA-Z]+:', target):
            assert (doc.parent / target).exists(), f'broken local link: {doc}: {target}'
assert all(case_id in (BASE / cg['procedure_path']).read_text() for case_id in expected)
assert all(kernel in (BASE / cg['spec_path']).read_text() for kernel in cg['calculator_kernels'])
print('PASS CGUI-1: 10 mandatory cases; 6 domain cards; 3 presentations/actions; final release traceability')
print(f'PASS deterministic truth fixtures, zero automatic requests, source identities and links; {cached_sources}/6 cached source bytes checked')
print('LIMIT static planning integrity only; no renderer, model, database, device, SDK installation or acceptance execution')
