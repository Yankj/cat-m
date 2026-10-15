#!/usr/bin/env python3
"""Prepare ignored UTF-8 review packages from exact received API19/tick7 bytes.
No credentials, network, deployment, default activation or frozen-source writes.
"""
from pathlib import Path
from hashlib import sha256
import difflib,json,tarfile,io
ROOT=Path(__file__).resolve().parents[1]
EDGE=ROOT/'services/edge'
OUT=EDGE/'build/model-route-review-20261015/packages-r7'
source=json.loads((EDGE/'deployed-baselines/2026-10-13/SOURCE.json').read_text())
review_id='catpaw-gemma-private-review-20261015-v1'
new_names=['core/src/private-route-review.mjs','model-route-review.mjs','model-route-review-probe.mjs']
def digest(data):return sha256(data).hexdigest()
def replace_once(text,old,new):
 assert text.count(old)==1,(old,text.count(old));return text.replace(old,new)
def provider_patch(text):
 text=replace_once(text,"import { safeProviderFailure } from './provider-errors.mjs';","import { safeProviderFailure } from './provider-errors.mjs';\nimport {matchesGemmaPrivateReview,checkGemmaReviewFrame} from './private-route-review.mjs';")
 # API19 preserves allowImageInput and its independent image guard branch.
 token='expectedProviderDisplay=null,allowImageInput=false}={})' if 'allowImageInput=false}={})' in text else 'expectedProviderDisplay=null}={})'
 text=replace_once(text,token,token.replace('}={})',',privateRouteReviewID=null}={})'))
 text=replace_once(text,'this.privateRoutingPolicy=privateRoutingPolicy;this.beforeStream=beforeStream;','this.privateRoutingPolicy=privateRoutingPolicy;this.privateRouteReviewID=privateRouteReviewID;this.beforeStream=beforeStream;')
 old="check(this.model===SUCCESSFUL_FREE_MODEL&&JSON.stringify(this.routingPolicy.only)===JSON.stringify(['novita/bf16'])&&Object.values(this.routingPolicy.max_price).every(v=>v===0)&&this.routingPolicy.only.length===1&&this.routingPolicy.allow_fallbacks===false&&this.routingPolicy.data_collection==='deny'&&typeof this.beforeStream==='function',503,'private_route_not_configured');"
 new="const original=this.privateRouteReviewID===null&&this.model===SUCCESSFUL_FREE_MODEL&&JSON.stringify(this.routingPolicy.only)===JSON.stringify(['novita/bf16'])&&Object.values(this.routingPolicy.max_price).every(v=>v===0)&&this.routingPolicy.only.length===1&&this.routingPolicy.allow_fallbacks===false&&this.routingPolicy.data_collection==='deny';const review=matchesGemmaPrivateReview({reviewID:this.privateRouteReviewID,model:this.model,expectedProviderDisplay:this.expectedProviderDisplay,routingPolicy:this.routingPolicy});check((original||review)&&typeof this.beforeStream==='function',503,'private_route_not_configured');"
 text=replace_once(text,old,new)
 text=replace_once(text,'this.#observations.push(evidence);',"const reviewFrames=matchesGemmaPrivateReview({reviewID:this.privateRouteReviewID,model:this.model,expectedProviderDisplay:this.expectedProviderDisplay,routingPolicy:this.routingPolicy})?{seen:{},validation:{schema_version:1,review_id:this.privateRouteReviewID,frames:0,passed:false}}:null;\n    if(reviewFrames)evidence.review_frame_validation=reviewFrames.validation;\n    this.#observations.push(evidence);")
 text=replace_once(text,"        if(typeof chunk.model==='string')evidence.actual_model","        if(reviewFrames)checkGemmaReviewFrame(chunk,reviewFrames);\n        if(typeof chunk.model==='string')evidence.actual_model")
 return replace_once(text,'      evidence.terminal_validated=true;','      if(reviewFrames)reviewFrames.validation.passed=true;\n      evidence.terminal_validated=true;')
def bootstrap_patch(text):
 text=replace_once(text,"import {createCloudRuntime} from './api.mjs';","import {createCloudRuntime} from './api.mjs';\nimport {selectGemmaReviewRequest,createGemmaShortTextProbeRuntime} from './model-route-review-probe.mjs';")
 text=replace_once(text,'let runtime:Promise<any>|undefined;','let runtime:Promise<any>|undefined,reviewRuntime:Promise<any>|undefined;')
 text=replace_once(text,'   const config=readConfig(get);','   const selected=selectGemmaReviewRequest(request,get,kind);\n   const config=readConfig(get);')
 text=replace_once(text,'   if(!runtime){const sql=', '   let selectedRuntime=selected.review?reviewRuntime:runtime;\n   if(!selectedRuntime){const sql=')
 old='runtime=verifyDedicatedPool(pool).then(()=>createCloudRuntime({repository,authenticate,config,retain,verifyToken}));'
 new="selectedRuntime=verifyDedicatedPool(pool).then(async()=>selected.review?await createGemmaShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID:selected.subjectID,scopeID:selected.scopeID,fetchImpl:globalThis.fetch,liveNetworkEnabled:true}):await createCloudRuntime({repository,authenticate,config,retain,verifyToken}));\n    if(selected.review)reviewRuntime=selectedRuntime;else runtime=selectedRuntime;"
 text=replace_once(text,old,new)
 return replace_once(text,"   const r=await runtime;return kind==='api'?r.api(request):r.tick(request);","   const r=await selectedRuntime;return kind==='api'?r.api(selected.request):r.tick(selected.request);")
OUT.mkdir(parents=True,exist_ok=True);packages=[]
integration_map=EDGE/'build/integration-import-map.json'
if integration_map.is_file():
 offline_map=json.loads(integration_map.read_text());offline_map['imports'].update({name:'node:'+name for name in ['os','fs','net','tls','crypto','stream','perf_hooks']})
 (OUT.parent/'check-import-map.json').write_text(json.dumps(offline_map)+'\n')
for f in source['functions']:
 label=f"{f['function']}-v{f['observed_version']}";base=EDGE/'deployed-baselines/2026-10-13'/label;dest=OUT/label
 originals={}
 for name,h in f['files'].items():
  data=(base/name).read_bytes();assert digest(data)==h,(label,name);originals[name]=data
 expected=dict(originals)
 for name in new_names:expected['_shared/'+name]=(EDGE/'supabase/functions/_shared'/name).read_bytes()
 for name,patch in [('_shared/core/src/openrouter-provider.mjs',provider_patch),('_shared/bootstrap.ts',bootstrap_patch)]:expected[name]=patch(originals[name].decode()).encode()
 if dest.exists():
  actual={str(p.relative_to(dest)):p.read_bytes() for p in dest.rglob('*') if p.is_file()}
  assert actual==expected,'existing package differs; keep old evidence and choose a fresh output version'
 else:
  for name,data in expected.items():p=dest/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
 changed=[];patches=[]
 for name in sorted(expected):
  before=originals.get(name,b'');after=expected[name]
  if before!=after:
   changed.append({'path':name,'status':'modified' if name in originals else 'added','base_sha256':digest(before) if name in originals else None,'candidate_sha256':digest(after)})
   patches.extend(difflib.unified_diff(before.decode().splitlines(keepends=True),after.decode().splitlines(keepends=True),fromfile='a/'+name if name in originals else '/dev/null',tofile='b/'+name))
 diff=''.join(patches).encode();(OUT/(label+'.diff')).write_bytes(diff)
 files={name:digest(data) for name,data in sorted(expected.items())};canonical=json.dumps(files,sort_keys=True,separators=(',',':')).encode()
 archive=OUT/(label+'.tar')
 with tarfile.open(archive,'w',format=tarfile.GNU_FORMAT) as tar:
  for name,data in sorted(expected.items()):
   info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;info.mtime=0;info.uid=info.gid=0;info.uname=info.gname='';tar.addfile(info,io.BytesIO(data))
 rollback=OUT/(label+'.rollback.tar')
 with tarfile.open(rollback,'w',format=tarfile.GNU_FORMAT) as tar:
  for name,data in sorted(originals.items()):
   info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;info.mtime=0;info.uid=info.gid=0;info.uname=info.gname='';tar.addfile(info,io.BytesIO(data))
 packages.append({'rollback_archive_file':rollback.name,'rollback_archive_sha256':digest(rollback.read_bytes()),'function':f['function'],'base_version':f['observed_version'],'base_bundle_ezbr_sha256':f['bundle_ezbr_sha256'],'base_file_count':len(originals),'candidate_file_count':len(expected),'package_tree_sha256':digest(canonical),'archive_file':archive.name,'archive_sha256':digest(archive.read_bytes()),'diff_file':label+'.diff','diff_sha256':digest(diff),'changed':changed,'files':files,'default_config_api_and_entry_bytes_preserved':all(expected[name]==originals[name] for name in [f['function']+'/index.ts','_shared/config.mjs','_shared/api.mjs']),'review_tick_enabled':False})
manifest={'schema':'catpaw.model-route-review-package.v1','review_id':review_id,'activation':'prepared_only_not_deployed','review_path_prefix':'/route-review/'+review_id,'review_scope':'new_explicit_synthetic_subject_and_empty_scope_only','probe':'one fixed original short-text operation, no context/attachments/tasks/revisions/tools; GET only after durable original exists','required_nonsecret_server_fields':['CATPAW_REVIEW_PROBE_ID','CATPAW_REVIEW_PROBE_SUBJECT_ID','CATPAW_REVIEW_PROBE_SCOPE_ID'],'default_original_handler_preserved':True,'review_auto_kick':False,'review_tick_enabled':False,'production_requests':0,'packages':packages}
(OUT/'PACKAGE-MANIFEST.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'manifest':str((OUT/'PACKAGE-MANIFEST.json').relative_to(ROOT)),'sha256':digest((OUT/'PACKAGE-MANIFEST.json').read_bytes()),'packages':[{'function':p['function'],'files':p['candidate_file_count'],'archive_sha256':p['archive_sha256'],'changed':len(p['changed'])} for p in packages]}))
