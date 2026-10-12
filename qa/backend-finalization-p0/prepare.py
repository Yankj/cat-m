#!/usr/bin/env python3
"""Extract only committed public source to QA runtime directories; inputs stay read-only."""
import argparse,pathlib,subprocess,hashlib,json,shutil
p=argparse.ArgumentParser();p.add_argument('--owner',type=pathlib.Path,required=True);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent;repo=root.parents[1];build=root/'build';build.mkdir(exist_ok=True)
commits={'before':'9d22974dd71ba7e122317c6968836dcfb4dd03b4','after':'14495bede7dcdb66956c52add6aca78b48764464'}
sha=lambda b:hashlib.sha256(b).hexdigest()
manifest=json.loads((a.owner/'services/edge/P0-FINALIZATION-MANIFEST.json').read_text())
checked={}
for section,prefix in [('source_files','services/edge/'),('preserved_baseline_files','services/edge/supabase/functions/')]:
    for name,digest in manifest[section].items():
        data=subprocess.check_output(['git','show',commits['after']+':'+prefix+name],cwd=repo)
        assert sha(data)==digest and (a.owner/(prefix+name)).read_bytes()==data
        checked[prefix+name]=digest
for version,commit in commits.items():
    target=build/version;assert not target.exists();target.mkdir()
    names=subprocess.check_output(['git','ls-tree','-r','--name-only',commit,'services/edge'],cwd=repo,text=True).splitlines()
    for name in names:
        if not name.endswith(('.mjs','.ts','.json','.lock','.md')):continue
        relative=pathlib.Path(name).relative_to('services/edge');output=target/relative;output.parent.mkdir(parents=True,exist_ok=True)
        output.write_bytes(subprocess.check_output(['git','show',commit+':'+name],cwd=repo))
    shutil.copyfile(root/'finalization.test.mjs',target/'test/qa-finalization.test.mjs')
cache=a.owner/'services/edge/build/cache/npm/registry.npmjs.org/jose/6.2.12'
assert (cache/'dist/webapi/index.js').is_file()
shutil.copytree(cache,build/'npm/jose')
(root/'INPUT-VERIFICATION.json').write_text(json.dumps({'commits':commits,'verified_owner_and_committed_files':checked,'dependency':'Existing official public jose 6.2.12 cache, no installation','synthetic_only':True},indent=2)+'\n')
print('PASS 4 source files + 6 preserved files; exact Git snapshots; copied public jose cache only')
