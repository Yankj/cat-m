#!/usr/bin/env python3
"""Maintain the native App's single version source and verify packaged identity."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = ROOT / 'Configuration/Version.xcconfig'
KEYS = ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION')

def read_version():
    text = VERSION.read_text()
    values = {}
    for key in KEYS:
        matches = re.findall(r'^' + key + r'\s*=\s*(\S+)\s*$', text, re.M)
        if len(matches) != 1:
            raise ValueError('Expected exactly one ' + key + ' in Version.xcconfig')
        values[key] = matches[0]
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', values[KEYS[0]]):
        raise ValueError('Version must use three numeric components, for example 0.3.1')
    if not re.fullmatch(r'[1-9][0-9]*', values[KEYS[1]]):
        raise ValueError('Build number must be a positive integer')
    return values

def check(values, app):
    project = ROOT / 'CatpawM.xcodeproj/project.pbxproj'
    objects = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
    native_project = next(x for x in objects.values() if x.get('isa') == 'PBXProject')
    configs = objects[native_project['buildConfigurationList']]['buildConfigurations']
    for identifier in configs:
        config = objects[identifier]
        reference = objects.get(config.get('baseConfigurationReference'), {})
        if reference.get('path') != 'Configuration/Version.xcconfig':
            raise ValueError(config['name'] + ' must inherit Version.xcconfig')
    for config in objects.values():
        if config.get('isa') == 'XCBuildConfiguration' and any(k in config.get('buildSettings', {}) for k in KEYS):
            raise ValueError('Version override in project configuration: ' + config['name'])
    device_config = (ROOT / 'Configuration/DeviceTrial.xcconfig').read_text()
    if any(re.search(r'^' + k + r'\s*=', device_config, re.M) for k in KEYS):
        raise ValueError('DeviceTrial must inherit the common App version')
    for name in ('Resources/Info.plist', 'Configuration/DeviceTrial.Info.plist'):
        info = plistlib.loads((ROOT / name).read_bytes())
        if info.get('CFBundleShortVersionString') != '$(MARKETING_VERSION)' or info.get('CFBundleVersion') != '$(CURRENT_PROJECT_VERSION)':
            raise ValueError(name + ' must use the Xcode version variables')
    if os.environ.get('TARGET_NAME') == 'CatpawM':
        for key in KEYS:
            if os.environ.get(key) != values[key]:
                raise ValueError('Build setting differs from Version.xcconfig: ' + key)
    if app:
        info = plistlib.loads((Path(app) / 'Info.plist').read_bytes())
        if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != tuple(values[k] for k in KEYS):
            raise ValueError('Packaged App version differs from Version.xcconfig')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('show', 'check', 'bump'))
    parser.add_argument('--version', help='Optional next marketing version; build always increases')
    parser.add_argument('--app', help='Check the built .app Info.plist as well')
    args = parser.parse_args()
    values = read_version()
    if args.command == 'bump':
        if args.app:
            parser.error('--app is only for check')
        check(values, None)
        next_version = args.version or values[KEYS[0]]
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', next_version):
            parser.error('--version must use three numeric components')
        if tuple(map(int, next_version.split('.'))) < tuple(map(int, values[KEYS[0]].split('.'))):
            parser.error('Marketing version cannot decrease')
        values = {KEYS[0]: next_version, KEYS[1]: str(int(values[KEYS[1]]) + 1)}
        temporary = VERSION.with_suffix('.xcconfig.writing')
        temporary.write_text('// Shared by Debug, Release and DeviceTrial. Use Scripts/app-version.py bump.\n' + ''.join(k + ' = ' + values[k] + '\n' for k in KEYS))
        temporary.replace(VERSION)
    elif args.version:
        parser.error('--version is only for bump')
    if args.command == 'check':
        check(values, args.app)
    print(('PASS ' if args.command == 'check' else '') + values[KEYS[0]] + ' (' + values[KEYS[1]] + ')')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit('App version check failed: ' + str(error))
