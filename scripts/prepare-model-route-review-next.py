#!/usr/bin/env python3
"""Prepare a bounded r8 API proposal from the exact previously approved API21 tar.
No network, credentials, Auth, deployment, new binding or tick package. Never overwrite
an existing candidate with different bytes. The maintained API is not the deployment base.
"""
from pathlib import Path
import argparse, hashlib, io, json, tarfile, difflib

ROOT=Path(__file__).resolve().parents[1]
BASE_SHA='eac493ce38634ef721c69be7cece91c6d0aa1b040f922a1a5247d14e4052c257'
REVIEW='catpaw-gemma-private-review-20261015-v2'
def sha(data):return hashlib.sha256(data).hexdigest()
def replace_once(text,old,new):
    if text.count(old)!=1:raise ValueError('base_patch_anchor_changed')
    return text.replace(old,new)
def archive(rows):
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode='w',format=tarfile.GNU_FORMAT) as tar:
        for name,data in sorted(rows.items()):
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644
            info.mtime=0;info.uid=info.gid=0;info.uname=info.gname=''
            tar.addfile(info,io.BytesIO(data))
    return buf.getvalue()
def prepare(base_path,out):
    raw=base_path.read_bytes()
    if sha(raw)!=BASE_SHA:raise ValueError('api21_base_archive_hash_changed')
    original={}
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:') as tar:
        for entry in tar:
            name=entry.name
            if not entry.isfile() or name.startswith('/') or '..' in Path(name).parts or name in original:raise ValueError('base_archive_entry_denied')
            original[name]=tar.extractfile(entry).read()
    if len(original)!=53 or 'catpaw-api/index.ts' not in original:raise ValueError('api21_base_entries_changed')
    candidate=dict(original)
    new_path='_shared/model-route-review-probe-next.mjs'
    candidate[new_path]=(ROOT/'services/edge/supabase/functions'/new_path).read_bytes()
    strict_path='_shared/core/src/strict-json.mjs'
    candidate[strict_path]=(ROOT/'services/edge/supabase/functions'/strict_path).read_bytes()
    old='_shared/model-route-review-probe.mjs'
    candidate[old]=replace_once(original[old].decode(), '   await repository.transaction(async tx=>{\n    const conversations=', "   if(request.method!=='GET')await repository.transaction(async tx=>{\n    const conversations=").encode()
    boot='_shared/bootstrap.ts';text=original[boot].decode()
    text=replace_once(text,"import {selectGemmaReviewRequest,createGemmaShortTextProbeRuntime} from './model-route-review-probe.mjs';", "import {selectGemmaReviewRequest,createGemmaShortTextProbeRuntime} from './model-route-review-probe.mjs';\nimport {selectGemmaNextReviewRequest,createGemmaNextShortTextProbeRuntime} from './model-route-review-probe-next.mjs';")
    text=replace_once(text,'let runtime:Promise<any>|undefined,reviewRuntime:Promise<any>|undefined;', 'let runtime:Promise<any>|undefined,reviewRuntime:Promise<any>|undefined,nextReviewRuntime:Promise<any>|undefined;')
    text=replace_once(text,'   const selected=selectGemmaReviewRequest(request,get,kind);', '   const next=selectGemmaNextReviewRequest(request,get,kind);\n   const selected=next.review?next:selectGemmaReviewRequest(request,get,kind);')
    text=replace_once(text,'let selectedRuntime=selected.review?reviewRuntime:runtime;', 'let selectedRuntime=next.review?nextReviewRuntime:selected.review?reviewRuntime:runtime;')
    text=replace_once(text,'selected.review?await createGemmaShortTextProbeRuntime(', 'next.review?await createGemmaNextShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID:selected.subjectID,scopeID:selected.scopeID,fetchImpl:globalThis.fetch,liveNetworkEnabled:true}):selected.review?await createGemmaShortTextProbeRuntime(')
    text=replace_once(text,'if(selected.review)reviewRuntime=selectedRuntime;else runtime=selectedRuntime;', 'if(next.review)nextReviewRuntime=selectedRuntime;else if(selected.review)reviewRuntime=selectedRuntime;else runtime=selectedRuntime;')
    candidate[boot]=text.encode()
    files={name:sha(data) for name,data in sorted(candidate.items())}
    tree_sha=sha(json.dumps(files,sort_keys=True,separators=(',',':')).encode())
    tar_bytes=archive(candidate)
    changed=[{'path':p,'status':'modified' if p in original else 'added','before_sha256':sha(original[p]) if p in original else None,'after_sha256':sha(candidate[p])} for p in sorted(candidate) if original.get(p)!=candidate[p]]
    if [x['path'] for x in changed]!=['_shared/bootstrap.ts','_shared/core/src/strict-json.mjs','_shared/model-route-review-probe-next.mjs','_shared/model-route-review-probe.mjs']:raise ValueError('unexpected_changed_path')
    patch=''.join(line for row in changed for line in difflib.unified_diff(original.get(row['path'],b'').decode().splitlines(keepends=True),candidate[row['path']].decode().splitlines(keepends=True),fromfile='a/'+row['path'] if row['path'] in original else '/dev/null',tofile='b/'+row['path']))
    manifest={'schema':'catpaw.model-route-review-package.v2','activation':'prepared_only_not_deployed','function':'catpaw-api','base_version':21,'expected_current_tick_version':8,'base_archive_sha256':BASE_SHA,'review_id':REVIEW,'review_prefix':'/route-review/'+REVIEW,'binding_review_id':'catpaw-gemma-private-review-20261015-v1','existing_subject_scope_only':True,'new_secrets':[],'new_identity':False,'auth_refresh':False,'limits':{'provider_attempts':1,'max_tokens':512,'provider_timeout_ms':30000,'max_price':{'prompt':0,'completion':0,'request':0,'image':0},'fallback':False,'context':0,'tools':0,'attachments':0},'default_route_and_image_runtime_preserved':True,'legacy_review_original_GET_preserved':True,'independent_review_runtime_cache':True,'base_file_count':len(original),'candidate_file_count':len(candidate),'package_tree_sha256':tree_sha,'archive_sha256':sha(tar_bytes),'rollback_archive_sha256':BASE_SHA,'changed':changed,'files':files,'actual_network_requests':0,'app_acceptance':False}
    outputs={**{'catpaw-api-v21/'+p:b for p,b in candidate.items()},'catpaw-api-v21.tar':tar_bytes,'catpaw-api-v21.rollback.tar':raw,'catpaw-api-v21.diff':patch.encode(),'PACKAGE-MANIFEST.json':(json.dumps(manifest,indent=2)+'\n').encode()}
    out.mkdir(parents=True,exist_ok=True)
    for name,data in outputs.items():
        p=out/name
        if p.exists() and p.read_bytes()!=data:raise ValueError('existing_candidate_differs_choose_new_output')
    for name,data in outputs.items():
        p=out/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
    return {k:manifest[k] for k in ['review_id','candidate_file_count','archive_sha256','package_tree_sha256','actual_network_requests']}
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--base-archive',type=Path,required=True);parser.add_argument('--output',type=Path,default=ROOT/'services/edge/build/model-route-review-20261015/packages-r8')
    args=parser.parse_args();print(json.dumps(prepare(args.base_archive,args.output)))
