#!/usr/bin/env python3
"""Validate FINAL-1 traceability and closure rules, without executing acceptance."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'docs/acceptance'
final = json.loads((BASE / 'catpaw-final-product-acceptance.json').read_text())
foundation = json.loads((ROOT / 'docs/planning/AF-1/contract.json').read_text())
functional = json.loads((BASE / 'agent-foundation-acceptance.json').read_text())
ux = json.loads((BASE / 'ios-codex-experience-acceptance.json').read_text())
assert final['version'] == 'FINAL-1'
assert final['foundation_contract_version'] == foundation['version']
assert final['foundation_final_goal'] == foundation['release_rules']['final_goal'] == 'AF-G5'

def by_id(items):
    result = {x['id']: x for x in items}
    assert len(result) == len(items), 'duplicate ID'
    return result

required_a = {x['id'] for x in functional['cases'] if x['required']}
required_u = {x['id'] for x in ux['cases'] if x['required']}
required_cp = {x['id'] for x in foundation['scenarios'] if x['required']}
for key, expected in [('acceptance_ids', required_a), ('ux_ids', required_u), ('scenario_ids', required_cp)]:
    assert set(final['foundation_required'][key]) == expected, key

quality = by_id(final['quality_checks'])
comparison = by_id(final['comparison_checks'])
goals = by_id(final['goals'])
assert set(quality) == {f'FQ-{i:02}' for i in range(1, 10)}
assert set(comparison) == {f'BP-{i:02}' for i in range(1, 9)}
assert set(goals) == {'FINAL-G1', 'FINAL-G2', 'FINAL-G3'}
assert goals['FINAL-G1']['requires_foundation_goal'] == 'AF-G5'
assert set(goals['FINAL-G1']['quality_ids']) == set(quality)
assert goals['FINAL-G2']['depends_on'] == ['FINAL-G1']
assert set(goals['FINAL-G2']['comparison_ids']) == set(comparison)
assert set(goals['FINAL-G3']['depends_on']) == {'FINAL-G1', 'FINAL-G2'}
work_units = by_id(foundation['work_units'])
design_units = by_id(foundation['design_work_units'])
for item in quality.values():
    assert item['required'] and item['assertions'] and item['minimum_evidence'], item['id']
    assert set(item['acceptance_ids']) <= required_a, item['id']
    assert set(item['ux_ids']) <= required_u, item['id']
    assert set(item.get('scenario_ids', [])) <= required_cp, item['id']
    assert set(item['work_units']) <= work_units.keys(), item['id']
    assert set(item['design_units']) <= design_units.keys(), item['id']
assert set(quality['FQ-06']['ux_ids']) == required_u
assert set(quality['FQ-09']['acceptance_ids']) == required_a
assert set(quality['FQ-09']['scenario_ids']) == required_cp
assert {'real_model', 'persistent_decision', 'physical_device'} <= set(quality['FQ-01']['minimum_evidence'])
assert {'real_database', 'multi_instance_trace'} <= set(quality['FQ-08']['minimum_evidence'])
assert set(final['card_types']) == {'choice', 'form', 'plan', 'approval', 'artifact', 'comparison'}
cg = json.loads((BASE / final['documents']['conversation_ui_acceptance']).read_text())
sub = final['conversation_ui_subcontract']
required_cg = {x['id'] for x in cg['cases'] if x['required']}
assert required_cg == {f'CG-A{i:02}' for i in range(1, 11)}
assert set(sub['case_ids']) == required_cg and sub['version'] == cg['version'] == 'CGUI-1'
assert set(sub['required_for_goals']) == {'FINAL-G1', 'FINAL-G3'}
assert not sub['foundation_goal_replaced']
assert set(quality['FQ-01']['required_subcontract']['case_ids']) == required_cg
assert quality['FQ-01']['required_subcontract']['path'] == sub['path']
assert goals['FINAL-G1']['required_subcontract_version'] == 'CGUI-1'
assert final['release_rules']['all_conversation_ui_cases_required']

q = final['quantitative_rules']
assert q['due_acceptance_max_seconds'] == 120 and q['minimum_touch_points'] == 44
assert q['text_contrast_minimum'] == 4.5 and q['control_contrast_minimum'] == 3
p = q['performance']
assert p['local_echo_p95_ms'] == 150 and p['valid_card_to_render_p95_ms'] == 250
assert p['local_decision_feedback_p95_ms'] == 500 and p['readonly_restore_start_max_seconds'] == 5
assert p['short_reply_first_text_p95_seconds'] == 10 and p['short_reply_complete_p95_seconds'] == 60
assert p['local_samples_per_metric_minimum'] >= 30 and p['real_short_reply_samples_minimum'] >= 20
assert p['percentile_method'] == 'nearest_rank' and p['include_failures_and_timeouts']
assert q['daily_use']['consecutive_days'] == 7 and q['daily_use']['real_sessions_minimum'] >= 10
assert q['daily_use']['all_three_scenarios_required']
c = final['comparison_rules']
assert c['all_checks_have_applicability_record_for_each_comparator']
assert c['common_executable_cases_per_comparator_minimum'] >= 4
assert c['paired_groups_per_case_minimum'] >= 5 and c['alternate_ab_ba']
assert c['improved_dimensions_minimum'] >= 2 and c['median_improvement_minimum_percent'] >= 20
assert c['unsupported_is_coverage_difference_not_speed_win'] and not c['not_run_or_blocked_can_be_win']
assert c['normal_ui_and_fault_injection_separate']
assert set(c['no_regression_dimensions']) == {'critical_correctness', 'authorization', 'actual_effects', 'data_preservation', 'recovery'}
assert {x['id'] for x in final['comparators']} == {'codex_mobile', 'openai_dots', 'xai_grok_bot', 'meta_muse'}
r = final['release_rules']
for key in ['same_release_candidate_required', 'all_foundation_cases_required', 'all_quality_checks_required', 'no_required_failures', 'no_p0_or_p1', 'unchanged_provider_route_first']:
    assert r[key], key
for key in ['missing_evidence_is_pass', 'prototype_replaces_native_acceptance', 'synthetic_replaces_real_model_or_database', 'additional_model_calls_authorized_by_this_document', 'new_packages_paid_resources_or_accounts_authorized_by_this_document', 'runtime_goal_status_changed']:
    assert not r[key], key
assert r['additional_compute_budget'] == 0
for target in final['documents'].values():
    assert (BASE / target).is_file(), target
procedure = (BASE / final['documents']['procedures']).read_text()
spec = (BASE / final['documents']['spec']).read_text()
assert all(key in procedure for key in [*quality, *comparison, *goals])
assert all(key in spec for key in goals)
for path in [(BASE / final['documents']['spec']), (BASE / final['documents']['procedures']), ROOT / 'docs/research/grok-companion-integration-review-2026-10-13.md']:
    assert path.read_text().count('```') % 2 == 0, path
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', path.read_text()):
        target = target.split('#', 1)[0]
        if target and not re.match(r'^[a-zA-Z]+:', target):
            assert (path.parent / target).exists(), f'broken local link: {path.name}: {target}'
assert foundation['documents']['final_product_acceptance'] == '../../acceptance/catpaw-final-product-acceptance.json'
assert foundation['final_product_contract']['runtime_goal_replaced'] is False
print('PASS FINAL-1: 3 goals; 9 mandatory quality checks; 8 comparison cases; 4 named comparators')
print('PASS 18 functional / 12 UX / 3 scenario mappings; work/design ownership; closure, thresholds and links')
print('LIMIT planning validation only; no native, model, database, scheduler, daily-use or competitor acceptance run')
