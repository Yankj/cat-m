#!/usr/bin/env python3
"""Verify frozen inputs and build disposable test copies; never write input files."""
import argparse, hashlib, json, pathlib, shutil, zipfile

p=argparse.ArgumentParser();p.add_argument('--artifacts',type=pathlib.Path,required=True);p.add_argument('--legacy-qa',type=pathlib.Path,required=True);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent
build=root/'build';build.mkdir(exist_ok=True)
expected={'Catpaw-iOS-Build13-Verified-Source.zip':('018395c17900d3fdea83256e33de0b16c412246588e88c286c3cdeae3e68764d','build13'), 'Catpaw-iOS-P0-State-Pending-Source-Patch-Tests.zip':('8ca70538aed8f0bc96f872d459bad02130de752b3cc460f296ccf192aae0af40','pending')}
results=[]
for name,(digest,version) in expected.items():
    archive=a.artifacts/name;data=archive.read_bytes();assert hashlib.sha256(data).hexdigest()==digest
    target=build/version
    assert not target.exists(),f'{version} output already exists; choose a new clean QA execution directory, never overwrite'
    with zipfile.ZipFile(archive) as z:
        assert all(not pathlib.PurePosixPath(n).is_absolute() and '..' not in pathlib.PurePosixPath(n).parts for n in z.namelist())
        manifests={}
        for m in ['SOURCE-SHA256.json','ALL-SOURCE-SHA256.json']:
            if m not in z.namelist():continue
            items=json.loads(z.read(m))
            assert all(hashlib.sha256(z.read(k)).hexdigest()==v for k,v in items.items())
            manifests[m]=len(items)
        z.extractall(target)
        results.append({'artifact':name,'sha256':digest,'bytes':len(data),'entries':len(z.infolist()),'verified_manifest_entries':manifests,'status':'PASS'})
legacy=build/'legacy';legacy.mkdir()
for name in ['P0ConversationScenarios.swift','P0PortableRunner.swift']:
    shutil.copyfile(a.legacy_qa/name,legacy/name)
    pinned={'P0ConversationScenarios.swift':'9c053b9ba6afe14719ac73d88f2cc4e857640b3840edda9c3f204e9edf2618fb','P0PortableRunner.swift':'bbd200cc54764c7cacb00397e553dbf109638fbfdef7700871fff0b2ee09e49b'}
    assert hashlib.sha256((legacy/name).read_bytes()).hexdigest()==pinned[name],f'legacy QA source changed: {name}'
    results.append({'legacy_test':name,'sha256':hashlib.sha256((legacy/name).read_bytes()).hexdigest()})
(root/'INPUT-VERIFICATION.json').write_text(json.dumps(results,indent=2)+'\n')

# The frozen extracted snapshots remain unmodified. Host changes occur in this third copy.
native=build/'native';native.mkdir()
for directory in ['Sources','Resources']:
    shutil.copytree(build/'pending'/directory,native/directory)
shutil.copyfile(root/'QAHost.swift',native/'Sources/App/CatpawApp.swift')
tests=native/'Tests';tests.mkdir()
for name in ['QAIndependentTests.swift','QAConversationScenarios.swift','QAFeedbackUITests.swift']:
    shutil.copyfile(root/name,tests/name)
shutil.copyfile(build/'pending/Tests/P0ConversationScenarios.swift',tests/'P0ConversationScenarios.swift')
scripts=native/'Scripts';scripts.mkdir()
generator=(build/'pending/Scripts/generate-project.py').read_text()
generator=generator.replace('Tests/ConversationFirstNativeTests.swift','Tests/QAIndependentTests.swift').replace("['Tests/AuthTestSupport.swift','Tests/NativeAuthNativeTests.swift']","['Tests/QAConversationScenarios.swift','Tests/P0ConversationScenarios.swift']").replace('Tests/ConversationFirstUITests.swift','Tests/QAFeedbackUITests.swift')
generator=generator.replace('com.example.CatpawM.ConversationFirst.Auth','com.example.CatpawM.QA.Dialogue').replace('SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;','SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG QA_PENDING";')
(scripts/'generate-project.py').write_text(generator)
import subprocess
subprocess.run(['python3',str(scripts/'generate-project.py')],check=True)
print('PASS zip/source manifests; frozen snapshots unchanged; disposable offline test host prepared')
