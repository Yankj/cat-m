#!/usr/bin/env python3
"""Exercise the actual scanner on isolated Git candidates, without secret output."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
SCANNER=ROOT/'scripts/scan-repository.py'


def make_fixture(root,files):
    (root/'scripts').mkdir(parents=True)
    shutil.copyfile(SCANNER,root/'scripts/scan-repository.py')
    (root/'scripts/reviewed-findings.json').write_text('{"findings":[]}\n')
    for name,contents in files.items():
        path=root/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(contents)
    subprocess.run(['git','init','--quiet',str(root)],check=True,capture_output=True)
    subprocess.run(['git','add','--force','--all','--','.'],cwd=root,check=True,capture_output=True)


def scan(root,secret=None):
    process=subprocess.run([sys.executable,str(root/'scripts/scan-repository.py')],cwd=root,capture_output=True,text=True)
    # Inspect both channels before raising an assertion. Never echo fixture bytes.
    if secret is not None:
        assert secret not in process.stdout and secret not in process.stderr,'Scanner exposed a suspected secret value'
    assert process.returncode in [0,1],'Scanner failed outside its finding protocol'
    return process.returncode,json.loads(process.stdout)


def run():
    with tempfile.TemporaryDirectory(prefix='catpaw-scan-fixture-') as directory:
        base=Path(directory)
        plain=base/'ordinary'/'candidate'
        managed=base/'.codex'/'worktrees'/'candidate'
        payload={'README.md':'Named synthetic candidate; no credentials.\n'}
        make_fixture(plain,payload)
        make_fixture(managed,payload)
        plain_result=scan(plain)
        managed_result=scan(managed)
        assert plain_result==managed_result,'Moving an identical candidate under a managed parent changed scanner output'
        assert plain_result[0]==0 and not plain_result[1]['blocking_hits'] and not plain_result[1]['manual_review_hits'],'Clean candidate did not pass'

        # All original directory rules, including the .build prefix, still apply
        # inside the Git candidate regardless of the checkout's parent location.
        excluded=['.codex','.aws','.build','.build-debug','DerivedData','node_modules','xcuserdata','.runtime']
        internal={name+'/candidate.txt':'Named synthetic fixture.\n' for name in excluded}
        internal_plain=base/'internal-ordinary'/'candidate'
        internal_managed=base/'.codex'/'internal-worktrees'/'candidate'
        make_fixture(internal_plain,internal)
        make_fixture(internal_managed,internal)
        internal_result=scan(internal_plain)
        assert internal_result==scan(internal_managed),'Internal exclusion results depend on checkout parent'
        assert internal_result[0]==1
        blocked={item['path'] for item in internal_result[1]['blocking_hits'] if item['category']=='excluded_directory_kind'}
        assert blocked==set(internal),'An original repository-relative directory exclusion was weakened'

        # Email rule (addresses assembled at runtime, like the credential fixture below): real dotted-domain addresses are still caught; @2x/@3x image scale names are not.
        emails=base/'email'/'candidate'
        make_fixture(emails,{'Contents.json':'{ "images" : [ { "filename" : "Mark@2x.png", "scale" : "2x" }, { "filename" : "Mark@3x.png", "scale" : "3x" } ] }\n',
                             'brand.py':'open("Logo@2x.png"); open("Logo@3x.pdf")\n',
                             'contact.txt':'mail reviewer.name'+'@'+'corp-mail.org\nshort a'+'@'+'x.cn\n'})
        email_result=scan(emails)
        email_hits={(item['path'],item.get('line')) for item in email_result[1]['manual_review_hits'] if item['category']=='email_review'}
        assert email_hits=={('contact.txt',1),('contact.txt',2)},'Email rule changed: real addresses must be caught, image scale names must not'
        assert email_result[0]==1

        # Construct a syntactically valid credential only in the temporary Git
        # candidate. It is never printed, committed or transmitted.
        secret='gh'+'p_'+hashlib.sha256(b'named scanner credential fixture').hexdigest()
        private=base/'credential'/'candidate'
        make_fixture(private,{'credential.txt':secret+'\n'})
        result=scan(private,secret)
        assert result[0]==1
        assert any(item['path']=='credential.txt' and item['category']=='credential_prefix' and item.get('line')==1 for item in result[1]['blocking_hits']),'Credential detection was weakened'

        # Existing pinned exceptions remain exact by path/category/line/hash;
        # changing candidate bytes must invalidate the review.
        report={'findings':[{'path':'credential.txt','category':'credential_prefix','line':1,'sha256':hashlib.sha256((secret+'\n').encode()).hexdigest(),'reason':'Named synthetic fixture; temporary test only.'}]}
        (private/'scripts/reviewed-findings.json').write_text(json.dumps(report)+'\n')
        reviewed=scan(private,secret)
        assert reviewed[0]==0 and reviewed[1]['reviewed_false_positives']==1,'Pinned review did not match exact synthetic bytes'
        (private/'credential.txt').write_text(secret+'\nChanged candidate bytes.\n')
        assert scan(private,secret)[0]==1,'Pinned review accepted changed candidate bytes'
    print('PASS actual Git fixtures: ordinary and managed-parent outputs match; all8 internal exclusions and credential detection remain active; no secret value output; pinned exceptions remain hash-bound')


if __name__=='__main__':
    run()
