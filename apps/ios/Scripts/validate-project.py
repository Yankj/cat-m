#!/usr/bin/env python3
"""Validate source membership, scheme, frozen spec and privacy settings without Xcode."""
import hashlib, json, pathlib, plistlib, subprocess, xml.etree.ElementTree as ET
root = pathlib.Path(__file__).resolve().parents[1]
project = root / 'CatpawM.xcodeproj'
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project/'project.pbxproj')]))['objects']
targets = {v['name']: v for v in objects.values() if v.get('isa') == 'PBXNativeTarget'}
def sources(target):
    result = []
    for phase in targets[target]['buildPhases']:
        if objects[phase]['isa'] == 'PBXSourcesBuildPhase':
            for build in objects[phase]['files']:
                path = objects[objects[build]['fileRef']]['path']
                assert (root/path).is_file(), path
                result.append(path)
    return result
app = sources('CatpawM'); tests = sources('CatpawMTests'); ui_tests = sources('CatpawMUITests')
expected = sorted(str(p.relative_to(root)) for p in (root/'Sources').rglob('*.swift'))
assert sorted(app) == expected and len(set(app)) == len(app)
assert len(app) == 36
assert tests == ['Tests/NativeTests.swift']
assert ui_tests == ['Tests/NativeUITests.swift']
resourcefiles=[]
for phase in targets['CatpawM']['buildPhases']:
    if objects[phase]['isa'] == 'PBXResourcesBuildPhase':
        for build in objects[phase]['files']:
            resource=objects[objects[build]['fileRef']]
            if resource['isa'] == 'PBXVariantGroup':
                resourcefiles.extend(objects[child]['path'] for child in resource['children'])
            else: resourcefiles.append(resource['path'])
assert sorted(resourcefiles) == ['Resources/UIStrings.json','Resources/en.lproj/InfoPlist.strings','Resources/zh-Hans.lproj/InfoPlist.strings']
assert all((root/path).is_file() for path in resourcefiles)
scheme = ET.parse(project/'xcshareddata/xcschemes/CatpawM.xcscheme')
assert len(scheme.findall('.//TestableReference')) == 2
info = plistlib.loads((root/'Resources/Info.plist').read_bytes())
assert 'UIBackgroundModes' not in info
checksums = json.loads((root/'docs/spec/SHA256.json').read_text())
for name, digest in checksums.items():
    assert hashlib.sha256((root/'docs/spec'/name).read_bytes()).hexdigest() == digest, name
print('PASS %d app sources, 1 native XCTest and 1 XCUITest source, shared scheme resolved' % len(app))
print('PASS %d frozen spec SHA-256 checks; no background modes' % len(checksums))
print('PASS UIStrings and both InfoPlist localizations registered in app resources')
print('LIMIT plist/source validation only; no iOS build, macros, linking, XCTest or UI run')
