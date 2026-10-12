#!/usr/bin/env python3
"""Curate synthetic evidence without machine paths, private data, or owner logs."""
import pathlib,json,hashlib,re,subprocess
root=pathlib.Path(__file__).resolve().parent;repo=root.parents[1];build=root/'build'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
runs=[]
for version,label in [('before','before-stage2'),('after','after-stage2')]:
    raw=(build/(label+'.tap')).read_text()
    counts={k:int(re.search(r'^# '+k+r' (\d+)$',raw,re.M).group(1)) for k in ['tests','pass','fail','cancelled','skipped']}
    cases=[{'case':m.group(2),'status':'PASS' if m.group(1)=='ok' else 'FAIL'} for m in re.finditer(r'^(ok|not ok) \d+ - (.+)$',raw,re.M)]
    runs.append({'version':version,'commit':json.loads((root/'INPUT-VERIFICATION.json').read_text())['commits'][version],'counts':counts,'cases':cases,'raw_log_sha256':sha(build/(label+'.tap')),'runtime_evidence':'build/'+label+'.tap'})
assert runs[0]['counts']=={'tests':1,'pass':0,'fail':1,'cancelled':0,'skipped':0}
assert runs[1]['counts']=={'tests':20,'pass':20,'fail':0,'cancelled':0,'skipped':0}
verification=json.loads((root/'INPUT-VERIFICATION.json').read_text())
for version,commit in verification['commits'].items():
    for path in (build/version/'supabase').rglob('*'):
        if not path.is_file():continue
        name='services/edge/'+str(path.relative_to(build/version))
        assert path.read_bytes()==subprocess.check_output(['git','show',commit+':'+name],cwd=repo)
result={'conclusion':'No blocker found in this patch at the audited synthetic layer; no cloud/product release approval','runs':runs,'runtime':'Existing Node 22.17.1 with transform-types and offline npm loader','database':'Serialized TestRepository and deterministic in-transaction fault injection','fixture':'Independent QA manually seeded admitted-shaped running turn; real production beforeFailure/fail/append/executeTool/complete/read gates','provider_dispatch_attempts':0,'real_auth_or_model_requests':0,'real_pg_connections':0,'tick_calls':0,'deployment':False,'post_test_git_source_identity':'PASS','not_run':['live PostgreSQL transaction isolation, row locks, concurrent multi-instance owner takeover','database disconnect/restart or process crash after COMMIT before notification','actual provider timeout and network delivery','real source authority/session/consent database checks','Deno runtime/full owner 62-case suite','cloud deployment and device/product acceptance'],'harness_only_initial_failure':'First invocation omitted Node transform-types: ERR_UNKNOWN_FILE_EXTENSION, no test body executed; flags corrected, raw before.tap/after.tap retained and not counted as patch failures'}
(root/'RESULTS.json').write_text(json.dumps(result,indent=2)+'\n')
(root/'SHA256.json').write_text(json.dumps({p.name:sha(p) for p in sorted(root.iterdir()) if p.is_file() and p.name!='SHA256.json'},indent=2)+'\n')
print('PASS expected before 0/1 red; after 20/20 green; exact source identity rechecked')
