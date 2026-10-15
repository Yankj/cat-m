#!/usr/bin/env python3
"""Validate the integrated P0 project's source membership and scheme references; no build/install."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project = root / 'CatpawM.xcodeproj'
objects = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(project / 'project.pbxproj')
]))['objects']
targets = {key: value for key, value in objects.items() if value.get('isa') == 'PBXNativeTarget'}
assert targets
app_sources = []
for identifier, target in targets.items():
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        if phase.get('isa') != 'PBXSourcesBuildPhase':
            continue
        paths = [objects[objects[build]['fileRef']]['path'] for build in phase['files']]
        assert len(paths) == len(set(paths)), target['name']
        assert all((root / path).is_file() for path in paths), target['name']
        if target['name'] == 'CatpawM':
            app_sources = paths
expected = sorted(str(path.relative_to(root)) for path in (root / 'Sources').rglob('*.swift'))
assert sorted(app_sources) == expected, 'App source membership differs from Sources tree'
for path in sorted((project / 'xcshareddata/xcschemes').glob('*.xcscheme')):
    for reference in ET.parse(path).findall('.//BuildableReference'):
        assert reference.attrib['BlueprintIdentifier'] in targets, path.name
subprocess.run(['python3', str(root / 'Scripts/app-version.py'), 'check'], check=True)
print(f'PASS {len(app_sources)} App source memberships; {len(targets)} targets; all shared scheme target references')
print('LIMIT static project validation only; no SDK, XCTest, UI or installation claim')
