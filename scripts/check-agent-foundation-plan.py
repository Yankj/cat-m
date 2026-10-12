#!/usr/bin/env python3
"""Validate requirement/acceptance ownership and the direct dependency DAG."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
plan = json.loads((root / 'docs/status/delivery-slices.json').read_text())
contract = json.loads((root / 'docs/acceptance/agent-foundation-acceptance.json').read_text())
spec = (root / 'docs/product/agent-foundation-spec.md').read_text()
procedures = (root / 'docs/acceptance/agent-foundation-acceptance.md').read_text()
slices = {item['id']: item for item in plan['slices']}
cases = {item['id']: item for item in contract['cases']}
assert len(slices) == len(plan['slices']), 'duplicate slice ID'
assert len(cases) == len(contract['cases']), 'duplicate acceptance ID'
requirements = {f'AF-R{i:02d}' for i in range(1, 13)}
assert all(item in spec for item in requirements), 'requirement missing from spec'
covered = set()
visited, active = set(), set()

def visit(sid):
    assert sid in slices, f'missing dependency {sid}'
    assert sid not in active, f'dependency cycle at {sid}'
    if sid in visited:
        return
    active.add(sid)
    item = slices[sid]
    assert item['kind'] in ['bootstrap', 'feature']
    assert len(set(item['depends_on'])) == len(item['depends_on'])
    for dependency in item['depends_on']:
        visit(dependency)
    active.remove(sid)
    visited.add(sid)

for sid, item in slices.items():
    visit(sid)
    assert set(item['requirements']) <= requirements
    for cid in item['acceptance_ids']:
        assert cid in cases and cases[cid]['owner_slice'] == sid, f'unowned {cid}'
        assert item['kind'] == 'feature', f'acceptance must have feature owner: {cid}'
        covered.add(cid)
for cid, case in cases.items():
    assert cid in covered, f'acceptance has no slice: {cid}'
    assert case['procedure_id'] == cid and cid in procedures
    assert set(case['requirements']) <= requirements
    assert case['minimum_evidence'], f'missing evidence layer: {cid}'
    if not case['required']:
        assert case.get('activation_requires'), f'unconfirmed extension missing gate: {cid}'
assert set().union(*(set(case['requirements']) for case in cases.values())) == requirements
print(f'PASS AF-1: {len(requirements)} requirements, {len(cases)} owned criteria, {len(slices)} acyclic slices; this is plan integrity, not product acceptance')
