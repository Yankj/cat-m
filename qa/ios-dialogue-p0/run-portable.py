#!/usr/bin/env python3
"""Run red/green independent tests and both legacy versions without any network."""
import pathlib, subprocess, os, json, argparse
parser=argparse.ArgumentParser();parser.add_argument('--pending-independent-only',action='store_true');args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent;build=root/'build'
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
compiler=subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()
results=json.loads((root/'PORTABLE-RESULTS.json').read_text())['runs'] if args.pending_independent_only else []
if args.pending_independent_only:results=[r for r in results if not (r['version']=='pending' and r['suite']=='independent')]
for version in (['pending'] if args.pending_independent_only else ['build13','pending']):
    source=build/version
    base=sorted((source/'Sources/Domain').glob('*.swift'))+[source/'Sources/Persistence/Repository.swift',source/'Sources/Persistence/BlobStore.swift',source/'Sources/Features/WorkspaceService.swift',source/'Sources/Features/ConversationSessionService.swift',source/'Sources/Features/ConversationFollowupQueueService.swift',source/'Sources/App/ConversationFirstModel.swift']
    scenarios=build/'legacy/P0ConversationScenarios.swift' if version=='build13' else source/'Tests/P0ConversationScenarios.swift'
    for suite in (['independent'] if args.pending_independent_only else ['independent','legacy']):
        flags=['-D','QA_PENDING'] if version=='pending' else []
        tests=[scenarios,root/'QAConversationScenarios.swift',root/'QAPortableRunner.swift'] if suite=='independent' else [scenarios,build/'legacy/P0PortableRunner.swift']
        output=build/(version+'-'+suite+('-stage2' if args.pending_independent_only else ''));output.mkdir()
        command=[compiler,'-swift-version','5','-target','arm64-apple-macosx14.0','-sdk',sdk,'-module-cache-path',str(build/'module-cache'),*flags,*map(str,base+tests),'-o',str(output/'runner')]
        with (output/'compile.log').open('w') as log:
            compiled=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        assert compiled.returncode==0,f'compile failure: {version}/{suite}'
        with (output/'run.log').open('w') as log:
            run=subprocess.run([str(output/'runner'),str(output/'data'),str(output/'results.json')],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((output/'results.json').read_text())
        results.append({'version':version,'suite':suite,'exit_code':run.returncode,'passed':report['passed'],'failed':report['failed'],'cases':report['cases'],'runtime_evidence':str(output.relative_to(root))})
        print(version,suite,report['passed'],'PASS',report['failed'],'FAIL',flush=True)
results.sort(key=lambda r: (['build13','pending'].index(r['version']),['independent','legacy'].index(r['suite'])))
(root/'PORTABLE-RESULTS.json').write_text(json.dumps({'runs':results,'no_real_model_or_auth_requests':True,'layer':'macOS Swift public model/service; FilePersistence; no iOS rendering or IME measurement'},indent=2,ensure_ascii=False)+'\n')
assert [(r['passed'],r['failed']) for r in results]==[(0,1),(7,1),(7,0),(8,0)],'unexpected red/green result; review exact failures'
