#!/usr/bin/env python3
"""Curate synthetic test evidence, excluding machine paths and simulator identifiers."""
import pathlib, subprocess, json, hashlib, re, argparse, zipfile
parser=argparse.ArgumentParser();parser.add_argument('--artifacts',type=pathlib.Path,required=True);args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent;build=root/'build'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
runs=[];lines=[]
for name in ['native-final','native-ui']:
    bundle=build/(name+'.xcresult')
    summary=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle),'--compact'],text=True))
    runs.append({k:summary[k] for k in ['title','result','totalTestCount','passedTests','failedTests','skippedTests','startTime','finishTime'] if k in summary})
    runs[-1].update({'evidence':'build/'+name+'.xcresult','log_sha256':sha(build/(name+'.log'))})
    text=(build/(name+'.log')).read_text()
    assert '** TEST SUCCEEDED **' in text
    lines += [name+': '+s for s in text.splitlines() if re.search(r"Test Case '-\[.*(?:passed|failed)|Executed \d+ test",s)]
assert runs[0]['totalTestCount']==9 and runs[0]['passedTests']==9 and runs[0]['failedTests']==0 and runs[0]['skippedTests']==0
assert runs[1]['totalTestCount']==1 and runs[1]['passedTests']==1 and runs[1]['failedTests']==0 and runs[1]['skippedTests']==0
snapshots=[]
for version in ['build13','pending']:
    source=build/version;checked={}
    for name in ['SOURCE-SHA256.json','ALL-SOURCE-SHA256.json']:
        if not (source/name).exists():continue
        manifest=json.loads((source/name).read_text());assert all(sha(source/k)==v for k,v in manifest.items());checked[name]=len(manifest)
    snapshots.append({'version':version,'verified_manifest_entries':checked,'mismatches':[]})
artifacts=json.loads((root/'INPUT-VERIFICATION.json').read_text())
for item in artifacts:
    if 'artifact' in item:assert sha(args.artifacts/item['artifact'])==item['sha256']
primary=['Sources/App/ConversationFirstModel.swift','Sources/Features/ConversationFirstView.swift','Sources/Features/ConversationFollowupQueueService.swift','Sources/Features/ConversationSessionService.swift','Sources/Persistence/Repository.swift','Sources/Persistence/SwiftDataPersistence.swift']
manifest=json.loads((build/'pending/SOURCE-SHA256.json').read_text())
for name in primary:assert sha(build/'native'/name)==manifest[name]
unchanged=0
for path in (build/'native/Sources').rglob('*.swift'):
    name=str(path.relative_to(build/'native'))
    if name=='Sources/App/CatpawApp.swift':continue
    assert sha(path)==manifest[name];unchanged+=1
result={'status':'PASS_WITH_PRODUCT_GATES_OPEN','runs':runs,'native_unit_unique_test_count':9,'unchanged_native_production_swift_files':unchanged,'qa_host_binary_sha256':sha(build/'DerivedData/Build/Products/Debug-iphonesimulator/CatpawM.app/CatpawM'),'legacy_behavior_case_count_within_one_native_test':8,'native_ui_test_count':1,'test_runtime':'iPhone 17 Simulator, iOS 27.0','toolchain':'Xcode 27.1 / iOS Simulator SDK 27.1; Swift 5 mode','synthetic_only':True,'auth_or_model_requests':0,'phone_installs':0,'deployments':0,'frozen_snapshot_post_run_verification':snapshots,'unchanged_production_sources':{name:manifest[name] for name in primary},'test_host_overlay':'QAHost.swift replaces Sources/App/CatpawApp.swift only in ignored build/native; QA bundle; production View bytes unchanged','not_measured':['touch-to-presented-frame <=100ms','real-device background 5s/30s','real weak network / Wi-Fi-cellular switch','native marked-text and keyboard command integration','active-only frames and scrolling']}
(root/'NATIVE-RESULTS.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
(root/'native-test-results.txt').write_text('\n'.join(lines)+'\n')
files=[p for p in root.iterdir() if p.is_file() and p.name!='QA-SHA256.json']
(root/'QA-SHA256.json').write_text(json.dumps({p.name:sha(p) for p in sorted(files)},indent=2)+'\n')
print('PASS final native 9/9, UI 1/1; zero failed/skipped; post-run frozen source identity intact')
