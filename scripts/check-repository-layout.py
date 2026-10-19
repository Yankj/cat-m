#!/usr/bin/env python3
"""Check declared local boundaries; no build, request, install or deployment."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
layout = json.loads((ROOT / 'docs/development/repository-layout.json').read_text())
assert layout['schema_version'] == 1
paths = [layout[k] for k in ['native_host', 'native_project', 'native_entry',
         'backend_maintenance', 'backend_shared', 'deployed_snapshots',
         'public_design', 'public_research', 'live_status', 'current_goal', 'website']]
for key in ['backend_entries_present', 'swift_packages', 'frozen_app_roots',
            'historical_service_roots', 'upstream_sources', 'retained_input_roots']:
    paths.extend(layout[key])
for name in paths:
    path = Path(name)
    assert not path.is_absolute() and '..' not in path.parts, name
    assert (ROOT / path).exists(), name
declared_apps = {Path(layout['native_host']).name, *(Path(p).name for p in layout['frozen_app_roots'])}
declared_apps.add(Path(layout['website']).name)
assert (ROOT / layout['website'] / 'package.json').is_file(), 'Website build manifest missing'
assert not list((ROOT / layout['website']).rglob('*.xcodeproj')), 'Website cannot become another native host'
actual_apps = {p.name for p in (ROOT / 'apps').iterdir() if p.is_dir() and not p.name.startswith('.')}
assert actual_apps == declared_apps, 'Undeclared App root; update reviewed layout roles first'
assert not (ROOT / 'CatCompanion').exists(), 'Second App skeleton cannot be imported as the active host'
project = (ROOT / layout['native_project'] / 'project.pbxproj').read_text()
for package in layout['swift_packages']:
    assert f'../../{package}' in project, package
    assert (ROOT / package / 'Package.swift').is_file(), package
    for source in (ROOT / package / 'Sources').rglob('*.swift'):
        text = source.read_text()
        assert not re.search(r'^\s*import\s+(CatpawM|Supabase)\b', text, re.M), source
        assert 'URLSession' not in text, source
entries = [p for p in (ROOT / layout['native_host'] / 'Sources').rglob('*.swift')
           if re.search(r'@main\b', p.read_text())]
assert entries == [ROOT / layout['native_entry']], entries
for source in (ROOT / layout['native_host'] / 'Sources/Domain').glob('*.swift'):
    assert not re.search(r'^\s*import\s+(SwiftUI|UIKit)\b', source.read_text(), re.M), source
assert not layout['second_active_app_allowed']
assert not layout['component_owned_model_or_auth_allowed']
assert not layout['deployment_implied_by_checks']
print('PASS one active native entry, independent website, two local packages, declared maintenance/history/source paths')
print('PASS Domain imports and package host/network boundaries; layout validation only')
