#!/usr/bin/env python3
"""Check cat display identity and unchanged install/data/wire identity against the pre-brand source."""
from pathlib import Path
import json, plistlib, re, subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='cb3bc90a6f35d93e9ad57a6c01c7dc83291d06ee'
def old(path):return subprocess.check_output(['git','show',f'{BASE}:{path}'],cwd=ROOT)
def renamed(path):return path.replace('CatpawM.xcodeproj','cat.xcodeproj').replace('CatpawM.entitlements','cat.entitlements').replace('Catpaw','cat').replace('CatPaw','cat')
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE],cwd=ROOT,text=True).splitlines()
checks=0
for name in ['Resources/Info.plist','Configuration/DeviceTrial.Info.plist','Widgets/CatpawWidgets/Info.plist']:
 p='apps/ios-conversation/'+name;a=plistlib.loads(old(p));b=plistlib.loads((ROOT/renamed(p)).read_bytes())
 assert b['CFBundleDisplayName' if 'CFBundleDisplayName' in b else 'CFBundleName']=='cat',p
 for k,v in a.items():
  if k not in {'CFBundleDisplayName','CFBundleName'} and not k.startswith('NS'):
   assert b[k]==v,(p,k);checks+=1
# Entitlements, package Bundle IDs, persistent keys, wire contracts and deep links must remain stable.
p='apps/ios-conversation/Configuration/CatpawM.entitlements'
assert old(p)==(ROOT/renamed(p)).read_bytes();checks+=1
p='apps/ios-conversation/CatpawM.xcodeproj/project.pbxproj'
ids=lambda t:re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*[^;]+;',t)
assert ids(old(p).decode())==ids((ROOT/renamed(p)).read_text());checks+=1
literal=re.compile(r'"(?:\\.|[^"\\])*"')
safe_display={'"Catpaw"','"CatPaw"','"Catpaw-m"','"Catpaw-workspace-export"'}
for p in paths:
 if not p.startswith(('apps/ios-conversation/Sources/','apps/ios-conversation/Widgets/')) or not p.endswith('.swift'):continue
 before=old(p).decode();after=(ROOT/renamed(p)).read_text()
 for token in set(literal.findall(before)):
  if re.search('catpaw',token,re.I) and not re.search(r'[\s\u3400-\u9fff]',token) and token not in safe_display:
   assert token in after,(p,token);checks+=1
for p in paths:
 if p.startswith(('services/edge/supabase/migrations/','services/edge/deployed-baselines/')) or p=='services/edge/supabase/config.toml':
  assert old(p)==(ROOT/p).read_bytes(),p;checks+=1
for base in ['apps/ios-conversation','packages']:
 for p in (ROOT/base).rglob('*'):
  if any(x.startswith('.build') or x=='build' for x in p.parts):continue
  assert not re.search('catpaw',p.name,re.I),p
ui=(ROOT/'apps/ios-conversation/Resources/UIStrings.json').read_text()
assert not re.search('catpaw|cat-m|猫爪',ui,re.I)
assert 'name: "catNavigation"' in (ROOT/'packages/ios-navigation/Package.swift').read_text()
assert 'name: "catImageComposer"' in (ROOT/'packages/ios-image-composer/Package.swift').read_text()
print(f'PASS cat brand identity and {checks} install/data/wire/frozen-backend compatibility checks')
print('LIMIT source invariants only; no installed-data upgrade, OAuth, live APNs, production model or database execution')
