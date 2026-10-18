#!/usr/bin/env python3
"""Single source of the native App's version and build identity.

Marketing version (SemVer X.Y.Z) lives in Configuration/Version.xcconfig and is changed on purpose with `bump`.
The build number is never typed by hand: it is the commit count of HEAD (`git rev-list --count HEAD`), stamped into
the processed Info.plist of the App and of every embedded extension by the `Stamp Build Info` build phase, together
with the build time (UTC ISO 8601), the short git SHA, a dirty flag and the configuration name.

Commands
  show            print `X.Y.Z (build N)` for the current checkout
  build-number    print N only (fails without full git history)
  check [--app]   verify project wiring; with --app also verify a packaged .app (version, build, SHA, stamp keys)
  bump LEVEL      major | minor | patch, or --version X.Y.Z; also opens the CHANGELOG section
  stamp           Xcode build phase only: write the identity keys into $TARGET_BUILD_DIR/$INFOPLIST_PATH
  release-check   release preflight: clean tree, full history, version newer than the last vX.Y.Z tag,
                  last tag is an ancestor of HEAD, CHANGELOG has the section; prints the tag to create (--json)
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
VERSION = ROOT / 'Configuration/Version.xcconfig'
CHANGELOG = REPO / 'CHANGELOG.md'
KEYS = ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION')
STAMP_KEYS = ('CatpawBuildDate', 'CatpawGitSHA', 'CatpawGitDirty', 'CatpawBuildConfiguration')
SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
HEADER = ('// Single version source for Debug, Release and DeviceTrial (App and widget).\n'
          '// MARKETING_VERSION: change only with Scripts/bump-version.sh (SemVer).\n'
          '// CURRENT_PROJECT_VERSION: fallback only. The real build number is the git commit count, stamped into the\n'
          '// packaged Info.plist by the "Stamp Build Info" phase (Scripts/app-version.py stamp).\n')
TAIL = ('\n// The stamp phase reads .git and edits the processed Info.plist; Xcode user-script sandboxing would block both.\n'
        'ENABLE_USER_SCRIPT_SANDBOXING = NO\n')

def read_version():
    text = VERSION.read_text()
    values = {}
    for key in KEYS:
        matches = re.findall(r'^' + key + r'\s*=\s*(\S+)\s*$', text, re.M)
        if len(matches) != 1:
            raise ValueError('Expected exactly one ' + key + ' in Version.xcconfig')
        values[key] = matches[0]
    if not SEMVER.fullmatch(values[KEYS[0]]):
        raise ValueError('Version must use three numeric components, for example 1.1.0')
    if not re.fullmatch(r'[1-9][0-9]*', values[KEYS[1]]):
        raise ValueError('Fallback build number must be a positive integer')
    return values

def write_version(marketing, fallback):
    temporary = VERSION.with_suffix('.xcconfig.writing')
    temporary.write_text(HEADER + 'MARKETING_VERSION = ' + marketing + '\nCURRENT_PROJECT_VERSION = ' + fallback + '\n' + TAIL)
    temporary.replace(VERSION)

def semver(text):
    return tuple(map(int, text.split('.')))

def git(*args, check=True):
    result = subprocess.run(['git', '-C', str(REPO), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ValueError('git ' + ' '.join(args) + ' failed: ' + result.stderr.strip())
    return result.stdout.strip() if result.returncode == 0 else None

def git_identity():
    """Return the build identity from git, or None when history is missing or shallow (e.g. CI depth-1 checkout)."""
    try:
        if git('rev-parse', '--is-inside-work-tree', check=False) != 'true':
            return None
        if git('rev-parse', '--is-shallow-repository', check=False) == 'true':
            return None
        count = git('rev-list', '--count', 'HEAD')
        sha = git('rev-parse', '--short=8', 'HEAD')
        # Tracked changes only: untracked scratch files do not change what Xcode compiles from the project.
        dirty = bool(git('status', '--porcelain', '--untracked-files=no', check=False))
        return {'build': count, 'sha': sha, 'dirty': dirty}
    except (OSError, ValueError):
        return None

def build_number(values, identity):
    return identity['build'] if identity else values[KEYS[1]]

def build_date():
    epoch = os.environ.get('SOURCE_DATE_EPOCH')   # reproducible-builds convention; release scripts may pin it
    moment = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc) if epoch else datetime.datetime.now(datetime.timezone.utc)
    return moment.replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')

def check(values, app):
    project = ROOT / 'CatpawM.xcodeproj/project.pbxproj'
    objects = json.loads(subprocess.check_output([shutil.which('plutil') or '/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
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
    for target in (x for x in objects.values() if x.get('isa') == 'PBXNativeTarget'):
        if target.get('productType') not in ('com.apple.product-type.application', 'com.apple.product-type.app-extension'):
            continue
        scripts = [objects[p] for p in target['buildPhases'] if objects[p].get('isa') == 'PBXShellScriptBuildPhase']
        if not any('app-version.py" stamp' in s.get('shellScript', '') for s in scripts):
            raise ValueError(target['name'] + ' must run the Stamp Build Info phase (App and extension builds must match)')
    device_config = (ROOT / 'Configuration/DeviceTrial.xcconfig').read_text()
    if any(re.search(r'^' + k + r'\s*=', device_config, re.M) for k in KEYS):
        raise ValueError('DeviceTrial must inherit the common App version')
    for name in ('Resources/Info.plist', 'Configuration/DeviceTrial.Info.plist', 'Widgets/CatpawWidgets/Info.plist'):
        info = plistlib.loads((ROOT / name).read_bytes())
        if info.get('CFBundleShortVersionString') != '$(MARKETING_VERSION)' or info.get('CFBundleVersion') != '$(CURRENT_PROJECT_VERSION)':
            raise ValueError(name + ' must use the Xcode version variables')
        if any(info.get(k) for k in STAMP_KEYS):
            raise ValueError(name + ' must not commit stamp values (' + ', '.join(STAMP_KEYS) + '); they are written at build time')
    if os.environ.get('TARGET_NAME') == 'CatpawM':
        for key in KEYS:
            if os.environ.get(key) != values[key]:
                raise ValueError('Build setting differs from Version.xcconfig (no command-line overrides): ' + key)
    if app:
        identity = git_identity()
        bundles = [Path(app)] + sorted((Path(app) / 'PlugIns').glob('*.appex'))
        for bundle in bundles:
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            if info.get('CFBundleShortVersionString') != values[KEYS[0]]:
                raise ValueError(bundle.name + ': packaged marketing version differs from Version.xcconfig')
            if identity and info.get('CFBundleVersion') != identity['build']:
                raise ValueError(bundle.name + ': packaged build ' + str(info.get('CFBundleVersion')) + ' != commit count ' + identity['build'])
            if identity and info.get('CatpawGitSHA') != identity['sha']:
                raise ValueError(bundle.name + ': packaged CatpawGitSHA differs from HEAD')
            if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', str(info.get('CatpawBuildDate', ''))):
                raise ValueError(bundle.name + ': CatpawBuildDate missing or not UTC ISO 8601')
        builds = {plistlib.loads((b / 'Info.plist').read_bytes()).get('CFBundleVersion') for b in bundles}
        if len(builds) != 1:
            raise ValueError('App and extensions carry different CFBundleVersion values: ' + ', '.join(sorted(map(str, builds))))

def stamp(values):
    target_dir, plist_path = os.environ.get('TARGET_BUILD_DIR'), os.environ.get('INFOPLIST_PATH')
    if not target_dir or not plist_path:
        raise ValueError('stamp runs only inside an Xcode build phase (TARGET_BUILD_DIR/INFOPLIST_PATH unset)')
    path = Path(target_dir) / plist_path
    raw = path.read_bytes()
    fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
    info = plistlib.loads(raw)
    identity = git_identity()
    configuration = os.environ.get('CONFIGURATION', '')
    if identity is None:
        print('warning: Stamp Build Info: no full git history (shallow or missing); using fallback build '
              + values[KEYS[1]] + '. Release packages must be built from a full clone.')
    wanted = {
        'CFBundleVersion': build_number(values, identity),
        'CatpawGitSHA': identity['sha'] if identity else '',
        'CatpawGitDirty': bool(identity and identity['dirty']),
        'CatpawBuildConfiguration': configuration,
    }
    # Same clean commit, same configuration, already stamped: leave the file untouched so a no-op build stays no-op.
    if not wanted['CatpawGitDirty'] and info.get('CatpawBuildDate') and all(info.get(k) == v for k, v in wanted.items()):
        print('Stamp Build Info: unchanged ' + values[KEYS[0]] + ' (' + wanted['CFBundleVersion'] + ')')
        return
    info.update(wanted)
    info['CatpawBuildDate'] = build_date()
    temporary = path.with_name(path.name + '.stamping')
    temporary.write_bytes(plistlib.dumps(info, fmt=fmt))
    temporary.replace(path)
    print('Stamp Build Info: ' + values[KEYS[0]] + ' (' + wanted['CFBundleVersion'] + ') ' + (wanted['CatpawGitSHA'] or 'no-git')
          + (' dirty' if wanted['CatpawGitDirty'] else '') + ' ' + info['CatpawBuildDate'])

def open_changelog_section(version):
    today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y-%m-%d')
    text = CHANGELOG.read_text() if CHANGELOG.exists() else '# Changelog\n\n## [Unreleased]\n'
    if re.search(r'^## \[' + re.escape(version) + r'\]', text, re.M):
        return
    if not re.search(r'^## \[Unreleased\]\s*$', text, re.M):
        raise ValueError('CHANGELOG.md needs a "## [Unreleased]" section')
    text = re.sub(r'^## \[Unreleased\]\s*$', '## [Unreleased]\n\n## [' + version + '] - ' + today, text, count=1, flags=re.M)
    CHANGELOG.write_text(text)

def tags():
    listed = git('tag', '--list', 'v*', check=False) or ''
    return sorted((t for t in listed.split() if SEMVER.fullmatch(t[1:])), key=lambda t: semver(t[1:]))

def release_check(values):
    problems = []
    identity = git_identity()
    marketing = values[KEYS[0]]
    tag = 'v' + marketing
    if identity is None:
        problems.append('full git history required (not shallow) so the build number is the commit count')
    elif identity['dirty']:
        problems.append('working tree has uncommitted tracked changes')
    existing = tags()
    head = git('rev-parse', 'HEAD', check=False)
    if tag in existing and git('rev-list', '-n', '1', tag, check=False) != head:
        problems.append(tag + ' already exists on another commit: run Scripts/bump-version.sh patch|minor|major')
    previous = [t for t in existing if semver(t[1:]) < semver(marketing)]
    if any(semver(t[1:]) > semver(marketing) for t in existing):
        problems.append('a newer tag than ' + tag + ' exists: ' + existing[-1])
    if previous and subprocess.run(['git', '-C', str(REPO), 'merge-base', '--is-ancestor', previous[-1], 'HEAD']).returncode != 0:
        problems.append(previous[-1] + ' is not an ancestor of HEAD; build numbers would not be monotonic')
    if not CHANGELOG.exists() or not re.search(r'^## \[' + re.escape(marketing) + r'\]', CHANGELOG.read_text(), re.M):
        problems.append('CHANGELOG.md has no "## [' + marketing + ']" section')
    elif not re.search(r'^## \[' + re.escape(marketing) + r'\] - \d{4}-\d{2}-\d{2}\s*$', CHANGELOG.read_text(), re.M):
        problems.append('CHANGELOG.md "## [' + marketing + ']" needs the release date (YYYY-MM-DD) on release day')
    try:
        check(values, None)
    except ValueError as error:
        problems.append(str(error))
    return {'ok': not problems, 'tag': tag, 'marketing_version': marketing, 'build': build_number(values, identity),
            'sha': identity['sha'] if identity else None, 'previous_tag': previous[-1] if previous else None, 'problems': problems}

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=('show', 'build-number', 'check', 'bump', 'stamp', 'release-check'))
    parser.add_argument('level', nargs='?', choices=('major', 'minor', 'patch'), help='bump only')
    parser.add_argument('--version', help='bump only: explicit next marketing version')
    parser.add_argument('--app', help='check only: also verify a built .app')
    parser.add_argument('--json', action='store_true', help='release-check only: machine-readable result')
    args = parser.parse_args()
    if (args.level or args.version) and args.command != 'bump':
        parser.error('level/--version are only for bump')
    if args.app and args.command != 'check':
        parser.error('--app is only for check')
    values = read_version()
    if args.command == 'bump':
        if bool(args.level) == bool(args.version):
            parser.error('bump needs exactly one of major|minor|patch or --version X.Y.Z')
        major, minor, patch = semver(values[KEYS[0]])
        next_version = args.version or {'major': f'{major + 1}.0.0', 'minor': f'{major}.{minor + 1}.0', 'patch': f'{major}.{minor}.{patch + 1}'}[args.level]
        if not SEMVER.fullmatch(next_version):
            parser.error('--version must use three numeric components')
        if semver(next_version) <= semver(values[KEYS[0]]):
            parser.error('Marketing version must increase (' + values[KEYS[0]] + ' -> ' + next_version + ')')
        check(values, None)
        write_version(next_version, values[KEYS[1]])
        open_changelog_section(next_version)
        print(values[KEYS[0]] + ' -> ' + next_version + '; CHANGELOG section opened; build number stays automatic')
        return
    if args.command == 'stamp':
        stamp(values)
        return
    if args.command == 'release-check':
        result = release_check(values)
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(('PASS ' if result['ok'] else 'FAIL ') + result['tag'] + ' build ' + result['build'] + (' ' + result['sha'] if result['sha'] else ''))
            for problem in result['problems']:
                print('  - ' + problem)
        sys.exit(0 if result['ok'] else 1)
    identity = git_identity()
    if args.command == 'build-number':
        if identity is None:
            raise ValueError('no full git history; build number unavailable')
        print(identity['build'])
        return
    if args.command == 'check':
        check(values, args.app)
    print(('PASS ' if args.command == 'check' else '') + values[KEYS[0]] + ' (build ' + build_number(values, identity) + ')'
          + ((' ' + identity['sha'] + (' dirty' if identity['dirty'] else '')) if identity else ' (fallback; no git history)'))

if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit('App version check failed: ' + str(error))
