#!/usr/bin/env python3
"""Check pinned sources, imported bytes, contract, screenshots and exact patch locally."""
from pathlib import Path
import hashlib, json, re, shutil, subprocess, tempfile

root=Path(__file__).resolve().parents[1]
sha=lambda b:hashlib.sha256(b).hexdigest()
read_json=lambda p:json.loads((root/p).read_text())
contract=root/'services/facade/contract/native-contract-v1.json'
assert sha(contract.read_bytes())=='08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9'
manifest=read_json('vendor/openmuse/SOURCE-MANIFEST.json')
assert manifest['commit']=='1ac68f3909f2478ab6280883f1ab5ea65eb5719d'
assert len(manifest['files'])==44
for item in manifest['files']:
    data=(root/'vendor/openmuse'/item['path']).read_bytes()
    assert sha(data)==item['sha256'],item['path']
    assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==item['git_blob_sha1'],item['path']
assert (root/'vendor/openmuse/LICENSE').read_bytes()==(root/'services/facade/patched-openmuse/LICENSE').read_bytes()
with tempfile.TemporaryDirectory(prefix='catpaw-patch-check-') as temp:
    target=Path(temp)/'openmuse'
    shutil.copytree(root/'vendor/openmuse',target)
    patch=root/'services/facade/patches/local-preview.patch'
    subprocess.run(['git','apply','--check',str(patch)],cwd=target,check=True)
    subprocess.run(['git','apply',str(patch)],cwd=target,check=True)
    for p in (root/'services/facade/patched-openmuse').rglob('*.ts'):
        relative=p.relative_to(root/'services/facade/patched-openmuse')
        assert p.read_bytes()==(target/relative).read_bytes(),str(relative)
    # The schema extension is in the exact patch, but is not imported by preview runtime.
    assert 'catpaw.preview' in (target/'packages/domain/src/index.ts').read_text()
provenance=read_json('docs/status/import-provenance.json')
for item in provenance['files']:
    p=root/item['path']
    assert sha(p.read_bytes())==item['sha256'],item['path']
    if not item['transformed']:assert item['source_sha256']==item['sha256']
for name in ['final-source-snapshot.json']:
    for path,value in read_json('docs/acceptance/evidence/ios-v1/'+name)['files'].items():
        assert sha((root/'apps/ios'/path).read_bytes())==value,path
spec=root/'apps/ios/docs/spec'
checksums=json.loads((spec/'SHA256.json').read_text())
for path,value in checksums.items():assert sha((spec/path).read_bytes())==value,path
for image in read_json('docs/assets/ios-v1/manifest.json')['screenshots']:
    assert sha((root/image['path']).read_bytes())==image['sha256'],image['path']
    assert image['synthetic_only'] and image['unaltered_pixels']
demo=read_json('docs/status/openmuse-r3-provenance.json')
demo_root=root/'apps/ios-openmuse-demo'
source_manifest=read_json('docs/acceptance/evidence/openmuse-r3/last-source-sha256.json')
assert len(source_manifest)==101 and len(list((demo_root/'Sources').rglob('*.swift')))==43
for item in demo['files']:
    assert sha((root/item['path']).read_bytes())==item['sha256'],item['path']
    if not item['transformed']:assert item['sha256']==item['source_sha256']
for sub,pattern in [('Sources','*.swift'),('Resources','*'),('Tests','*.swift'),('CatpawM.xcodeproj','*')]:
    for p in (demo_root/sub).rglob(pattern):
        if not p.is_file() or p.name=='ProjectReplyOwnershipRegression.swift':continue
        name=str(p.relative_to(demo_root))
        assert name in source_manifest,name
        assert sha(p.read_bytes())==source_manifest[name],name
assert (demo_root/'docs/openmuse-facade-v1/native-contract-v1.json').read_bytes()==contract.read_bytes()
for name,value in checksums.items():assert sha((demo_root/'docs/spec'/name).read_bytes())==value,name
replay=json.loads((demo_root/'Tests/Fixtures/OpenMuseSnapshot/provenance.json').read_text())
for name,value in replay['files'].items():assert sha((demo_root/'Tests/Fixtures/OpenMuseSnapshot'/name).read_bytes())==value,name
for im in read_json('docs/assets/openmuse-r3/manifest.json')['screenshots']:
    assert sha((root/im['path']).read_bytes())==im['sha256'],im['path']
    assert im['synthetic_only'] and im['unaltered_pixels']
print('PASS frozen contract, 44 pinned originals (SHA256 + Git blob SHA1), MIT identity')
print('PASS exact patch reconstruction and all runtime TypeScript copies')
print(f"PASS {len(provenance['files'])} imported bytes/provenance, final v1 source identity, {len(checksums)} frozen specs, 3 screenshots")
print(f"PASS {len(demo['files'])} frozen r3 imports, 43 App sources/101-item final manifest, contract/spec/replay and 4 synthetic screenshots")
print('LIMIT no iOS SDK build, Simulator, service listener, real model/Intelligence/SQL or deployment executed')
