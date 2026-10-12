#!/usr/bin/env python3
"""Verify immutable source received from the authenticated deployment API."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
baseline = root / 'services/edge/deployed-baselines/2026-10-13'
manifest = json.loads((baseline / 'SOURCE.json').read_text())
contents = []
counts = []
for function in manifest['functions']:
    folder = baseline / f"{function['function']}-v{function['observed_version']}"
    expected = function['files']
    actual = {str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file()}
    assert actual == set(expected), f"Unexpected/missing files: {function['function']}"
    data = {}
    for name, digest in expected.items():
        path = Path(name)
        assert not path.is_absolute() and '..' not in path.parts
        raw = (folder / path).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == digest, f'Changed deployed source: {name}'
        data[name] = raw
    counts.append(len(data))
    contents.append(data)
drift = sorted(p for p in contents[0].keys() & contents[1].keys()
               if contents[0][p] != contents[1][p])
assert drift == manifest['common_files_with_different_content']
print(f'PASS deployed source snapshots: {counts}, {len(drift)} shared-file differences preserved')
