#!/usr/bin/env python3
"""v1.2 capability manifest check.

docs/product/capabilities/cat-capabilities.json is the single source of truth for what mimi / 小咪 can do.
This check fails when:
  * the manifest is malformed (ids, status, planned entries carrying a UI entry, ...);
  * a UI anchor (accessibility identifier) named in the manifest does not exist in the iOS app or navigation package;
  * an in-app link (catpawm://<host>) is not handled by catAppRoute in DeepLinks.swift;
  * the backend mirror services/edge/supabase/functions/_shared/capabilities.mjs is out of sync.
`--write` regenerates the backend mirror's data block from the manifest.
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'docs/product/capabilities/cat-capabilities.json'
MIRROR = ROOT / 'services/edge/supabase/functions/_shared/capabilities.mjs'
SOURCES = [ROOT / 'apps/ios-conversation/Sources', ROOT / 'packages/ios-navigation/Sources']
DEEPLINKS = ROOT / 'apps/ios-conversation/Sources/Domain/DeepLinks.swift'
START = 'export const catCapabilities=Object.freeze('
errors = []
m = json.loads(MANIFEST.read_text())
if m.get('product') != 'mimi': errors.append('product display name must be mimi')
if not all(name in m.get('identity', '') for name in ('mimi', '小咪')):
    errors.append('identity must name mimi / 小咪')
# Check display prose only; ids, anchors, exports and catpawm:// links are stable internal identifiers.
display = [('identity', m.get('identity', ''))]
for c in m.get('capabilities', []):
    display.extend((f'{c.get("id", "?")}.{k}', c.get(k, '')) for k in ('name', 'purpose', 'trigger', 'limits'))
    display.extend((f'{c.get("id", "?")}.ui_entry.{k}', (c.get('ui_entry') or {}).get(k, '')) for k in ('label', 'button'))
for field, value in display:
    if re.search(r'\bcat(?:paw)?(?:-m)?\b', value, re.I | re.ASCII): errors.append(f'{field}: legacy display brand')
data = json.dumps(m, ensure_ascii=False, indent=1)
mirror = MIRROR.read_text()
i = mirror.index(START) + len(START); j = mirror.index(');\n', i)
if '--write' in sys.argv:
    MIRROR.write_text(mirror[:i] + data + mirror[j:]); mirror = MIRROR.read_text(); print('wrote', MIRROR.relative_to(ROOT))
if json.loads(mirror[i:mirror.index(');\n', i)]) != m:
    errors.append('backend mirror out of sync: run scripts/check-capabilities.py --write')
swift = '\n'.join(p.read_text(errors='ignore') for s in SOURCES for p in s.rglob('*.swift'))
deeplinks = DEEPLINKS.read_text()
ids = set()
for c in m.get('capabilities', []):
    cid = c.get('id', '?')
    if cid in ids: errors.append(f'{cid}: duplicate id')
    ids.add(cid)
    for k in ('name', 'purpose'):
        if not c.get(k): errors.append(f'{cid}: missing {k}')
    status, entry = c.get('status'), c.get('ui_entry')
    if status == 'planned':
        if entry is not None: errors.append(f'{cid}: planned capability must not have a ui_entry')
        if not c.get('planned_for'): errors.append(f'{cid}: planned capability needs planned_for')
        continue
    if status != 'shipped': errors.append(f'{cid}: status must be shipped or planned'); continue
    if not entry or not entry.get('anchor'): errors.append(f'{cid}: shipped capability needs ui_entry.anchor'); continue
    if f'"{entry["anchor"]}"' not in swift: errors.append(f'{cid}: anchor {entry["anchor"]!r} not found in iOS sources')
    link = entry.get('link')
    if link:
        mm = re.fullmatch(r'catpawm://([a-z]+)', link)
        if not mm: errors.append(f'{cid}: bad link {link!r}')
        elif f'case "{mm.group(1)}"' not in deeplinks: errors.append(f'{cid}: link host {mm.group(1)!r} not handled in DeepLinks.swift')
        if not entry.get('button'): errors.append(f'{cid}: link needs a button label')
if errors:
    print('check-capabilities: FAIL'); [print(' -', e) for e in errors]; sys.exit(1)
print(f'check-capabilities: OK ({len(ids)} capabilities)')
