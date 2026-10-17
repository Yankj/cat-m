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

# Launch screen guard (v1 letterbox blocker, 2026-10-17). A missing/invalid launch screen puts the app in legacy
# compatibility mode; a launch storyboard that names an asset the catalog lacks draws a blank first frame.
import plistlib, re, sys
launch_name = 'LaunchScreen'
for plist_path in ('Resources/Info.plist', 'Configuration/DeviceTrial.Info.plist'):
    info = plistlib.loads((root / plist_path).read_bytes())
    assert info.get('UILaunchStoryboardName') == launch_name or isinstance(info.get('UILaunchScreen'), dict), \
        f'{plist_path}: no UILaunchStoryboardName={launch_name} (or UILaunchScreen dict)'
storyboard = root / f'Resources/{launch_name}.storyboard'
assert storyboard.is_file(), f'{storyboard} missing'
app = next(t for t in targets.values() if t['name'] == 'CatpawM')
resources = [objects[objects[b]['fileRef']].get('path', '') for ph in app['buildPhases'] if objects[ph].get('isa') == 'PBXResourcesBuildPhase' for b in objects[ph]['files']]
assert f'Resources/{launch_name}.storyboard' in resources, 'LaunchScreen.storyboard is not in the CatpawM Copy Bundle Resources phase'
doc = ET.parse(storyboard).getroot()
assert doc.attrib.get('launchScreen') == 'YES' and doc.attrib.get('initialViewController'), 'LaunchScreen.storyboard is not a launch screen with an initial view controller'
catalog = root / 'Resources/Assets.xcassets'
def in_catalog(name, ext):
    return any(catalog.rglob(f'{name}.{ext}'))
for el in doc.iter():
    if el.tag in ('imageView', 'image') and el.attrib.get('image', el.attrib.get('name')) and el.tag == 'imageView':
        assert in_catalog(el.attrib['image'], 'imageset'), f'LaunchScreen image {el.attrib["image"]} not in Assets.xcassets'
    if el.tag == 'color' and el.attrib.get('name'):
        assert in_catalog(el.attrib['name'], 'colorset'), f'LaunchScreen colour {el.attrib["name"]} not in Assets.xcassets'
# Launch logo must never stretch (user report 15:14): aspect-fit, equal fixed width/height, square vector artboard.
for iv in doc.iter('imageView'):
    assert iv.attrib.get('contentMode') == 'scaleAspectFit', 'LaunchScreen image view must be scaleAspectFit'
    consts = {c.attrib.get('firstAttribute'): c.attrib.get('constant') for c in iv.iter('constraint') if 'secondItem' not in c.attrib}
    assert consts.get('width') and consts.get('width') == consts.get('height'), f'LaunchScreen image needs equal fixed width/height, got {consts}'
    for pdf in catalog.rglob(f"{iv.attrib['image']}.imageset/*.pdf"):
        import zlib
        raw = pdf.read_bytes(); blobs = [raw]
        for st in re.findall(rb'stream\r?\n(.*?)endstream', raw, re.S):
            try: blobs.append(zlib.decompress(st))
            except zlib.error: pass
        box = next((m for b in blobs for m in [re.search(rb'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]', b)] if m), None)
        assert box, f'{pdf.name}: no MediaBox'
        x0, y0, x1, y1 = map(float, box.groups())
        assert abs((x1 - x0) - (y1 - y0)) < 0.01, f'{pdf.name}: artboard {x1-x0}x{y1-y0} is not square'
    imageset = next(catalog.rglob(f"{iv.attrib['image']}.imageset"))
    entries = json.loads((imageset / 'Contents.json').read_text())['images']
    for entry in entries:
        if not entry.get('filename', '').endswith('.png'): continue
        head = (imageset / entry['filename']).read_bytes()[:24]
        w, h = int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big')
        scale = int(entry.get('scale', '1x').rstrip('x'))
        assert w == h == int(consts['width']) * scale, f"{entry['filename']}: {w}x{h} px, expected square {int(consts['width']) * scale} px"
    # Rasterised @1x/@2x/@3x PNGs, not a vector-only PDF: the out-of-process launch-screen renderer drew no logo from it.
    assert {e.get('scale') for e in entries if e.get('filename', '').endswith('.png')} >= {'2x', '3x'}, 'LaunchScreen logo needs @2x and @3x PNGs'
pinned = [c for c in doc.iter('constraint') if c.attrib.get('firstAttribute') in ('leading', 'trailing', 'top', 'bottom') and c.attrib.get('firstItem') == 'I01']
assert not pinned, 'LaunchScreen logo must be centred, never edge-pinned'
# Optional: the BUILT bundle (python3 validate-project.py --built-app path/CatpawM.app)
if '--built-app' in sys.argv:
    built = Path(sys.argv[sys.argv.index('--built-app') + 1])
    binfo = plistlib.loads((built / 'Info.plist').read_bytes())
    name = binfo.get('UILaunchStoryboardName')
    assert name == launch_name, f'built Info.plist UILaunchStoryboardName={name!r}'
    sbc = built / f'{name}.storyboardc'
    assert (sbc / 'Info.plist').is_file() and any(sbc.glob('*.nib')), f'{sbc} missing or empty'
    assert (built / 'Assets.car').is_file(), 'built app has no Assets.car'
    print(f'PASS built app {built.name}: UILaunchStoryboardName={name}, {sbc.name} present')
print('PASS launch screen: Info.plists name LaunchScreen; storyboard in Copy Bundle Resources; its image/colour assets exist')
print(f'PASS {len(app_sources)} App source memberships; {len(targets)} targets; all shared scheme target references')
print('LIMIT static project validation only; no SDK, XCTest, UI or installation claim')
