#!/bin/zsh
# Explicit build24 native review through the local synthetic maintenance API.
# No external Auth, model, SQL, dependency install, or automatic message send.
set -eu
cd "$(dirname "$0")/../../.."
mode="${1:-work}"
(( $# <= 1 )) || { print -u2 'Expected only work or resume.'; exit 2; }
device="${CATPAW_REVIEW_DEVICE:-949DAB72-1A93-4ECF-86E3-2E487B25C27E}"
text_size="${CATPAW_REVIEW_TEXT_SIZE:-large}"
app="build/native-accepted-work-20261015/DerivedData/Build/Products/Debug-iphonesimulator/CatpawM.app"
result="docs/acceptance/evidence/native-accepted-work-20261015/RESULT.json"
case "$mode" in
  work|resume) ;;
  *) print -u2 'Usage: zsh apps/ios-conversation/Scripts/run-simulator-review24.sh [work|resume]'; exit 2 ;;
esac
case "$text_size" in
  extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large) ;;
  *) print -u2 'CATPAW_REVIEW_TEXT_SIZE must be a supported simctl content_size value.'; exit 2 ;;
esac
[[ -d "$app" && -f "$result" ]] || { print -u2 'The final build24 package or curated RESULT.json is absent. No installation or launch was performed.'; exit 1; }
/usr/bin/python3 - "$app" "$result" <<'PY'
import hashlib,json,plistlib,sys
from pathlib import Path
package,result=map(Path,sys.argv[1:])
with (package/'Info.plist').open('rb') as file: info=plistlib.load(file)
assert str(info.get('CFBundleVersion'))=='24','Expected build24; refusing an ambiguous package'
assert info.get('CFBundleIdentifier')=='com.example.CatpawM.ConversationFirst.Auth','Unexpected review bundle identity'
keys=('CatpawSupabaseProjectURL','CatpawSupabasePublishableKey','CatpawBackendOrigin','CatpawServerScopeID','CatpawEdgeRegion')
assert not any(info.get(key) for key in keys),'Synthetic review refuses a cloud-configured package'
rows=[{'path':str(p.relative_to(package)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(package.rglob('*')) if p.is_file()]
fingerprint=hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(',',':')).encode()).hexdigest()
expected=json.loads(result.read_text())['package']['bundle_sha256']
assert isinstance(expected,str) and len(expected)==64 and fingerprint==expected,'Review package differs from the fixed build24 candidate'
print('Verified build24 package: '+fingerprint)
PY
# Check an existing, available Simulator before starting any local service.
# No create, erase, uninstall, container reset, or phone operations.
device_state="$(/usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); matches=[x for xs in d["devices"].values() for x in xs if x["udid"]==sys.argv[1]]; assert len(matches)==1,"Requested existing Simulator is unavailable"; print(matches[0]["state"])' "$device")"
/usr/bin/python3 - <<'PY'
import errno,fcntl,json,os,subprocess,time,urllib.error,urllib.request
from pathlib import Path
root=Path.cwd()
local=root/'build/native-accepted-work-20261015'
server_dir=root/'services/edge/build/native-accepted-work-20261015'
local.mkdir(parents=True,exist_ok=True)
server_dir.mkdir(parents=True,exist_ok=True)
origin='http://127.0.0.1:8767'
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        raise RuntimeError('Loopback fixture redirects are refused')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
def unique_object(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise RuntimeError('Duplicate fixture metadata field')
        result[key]=value
    return result
def probe():
    try:
        request=urllib.request.Request(origin+'/testing/v1/fixture',headers={'Accept':'application/json'})
        with opener.open(request,timeout=2) as response:
            if response.status!=200 or response.headers.get_content_type()!='application/json':
                raise RuntimeError('Existing port 8767 is not the required fixture')
            data=response.read(128001)
        if len(data)>128000: raise RuntimeError('Fixture metadata exceeds review limit')
        value=json.loads(data,object_pairs_hook=unique_object)
        provenance=value.get('provenance',{})
        if not (value.get('fixture_kind')=='actual_cloud_native_loopback_v1' and value.get('mode')=='normal' and value.get('origin')==origin and value.get('authentication')=='explicit_test_fixture_session' and value.get('model_reality')=='injected_synthetic_fixture' and value.get('real_supabase_login_verified') is False and all(provenance.get(key) is False for key in ('real_auth','real_model','real_sql'))):
            raise RuntimeError('Port 8767 has incompatible metadata; it was not stopped or reused')
        return value
    except urllib.error.URLError as error:
        if isinstance(error.reason,OSError) and error.reason.errno==errno.ECONNREFUSED: return None
        raise RuntimeError('Cannot verify port 8767; no existing service was stopped') from error
# Serialize only this entrypoint's possible start. A listening service must pass probe().
with (server_dir/'review-server24-start.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    metadata=probe()
    if metadata is None:
        runtime_file=local/'review-runtime.json'
        runtime=json.loads(runtime_file.read_text()) if runtime_file.is_file() else {}
        executable=os.environ.get('CATPAW_DENO_BIN') or runtime.get('deno_bin')
        cache=os.environ.get('CATPAW_PUBLIC_NPM_CACHE') or runtime.get('public_npm_cache')
        if not (isinstance(executable,str) and executable and Path(executable).is_absolute() and Path(executable).is_file() and os.access(executable,os.X_OK) and isinstance(cache,str) and cache and Path(cache).is_absolute() and Path(cache).is_dir()):
            raise SystemExit('No verified local fixture is running. Supply existing CATPAW_DENO_BIN and CATPAW_PUBLIC_NPM_CACHE, or ignored review-runtime.json with deno_bin/public_npm_cache. Dependencies will not be installed.')
        import_map=root/'services/edge/build/integration-import-map.json'
        script=root/'services/edge/test/fixtures/native-accepted-work-server.mjs'
        if not import_map.is_file() or not script.is_file(): raise SystemExit('Existing fixture source/import map is absent; nothing was installed.')
        state=server_dir/'review-server24.json'
        log_path=server_dir/'review-server24.log'
        command=[executable,'run','--no-check','--ignore-env','--cached-only','--allow-read','--allow-write='+str(server_dir),'--allow-net=127.0.0.1:8767','--import-map',str(import_map),str(script),'--port=8767','--mode=normal','--state='+str(state)]
        environment={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'DENO_DIR':cache}
        with log_path.open('ab') as log:
            child=subprocess.Popen(command,cwd=root,env=environment,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        (server_dir/'review-server24.pid').write_text(str(child.pid)+'\n')
        deadline=time.monotonic()+25
        while time.monotonic()<deadline:
            if child.poll() is not None: raise SystemExit('Local fixture exited. Inspect '+str(log_path)+'; no service was stopped.')
            metadata=probe()
            if metadata is not None: break
            time.sleep(.25)
        if metadata is None: raise SystemExit('Local fixture readiness was not confirmed. Inspect '+str(log_path)+'; no service was stopped.')
    print('Verified loopback fixture: actual maintenance API with synthetic Auth/model/SQL; original server snapshots are preserved.')
PY
# Clear all inherited simulator child variables, including QA font overrides.
clean_launch=(env)
for key in ${(k)parameters}; do
  if [[ "$key" == SIMCTL_CHILD_* ]]; then clean_launch+=(-u "$key"); fi
done
store="$(/usr/bin/python3 - "$mode" "$device" "$result" <<'PY'
import json,os,sys,uuid
from pathlib import Path
mode,device,result=sys.argv[1:]
path=Path('build/native-accepted-work-20261015/review-client.json')
fingerprint=json.loads(Path(result).read_text())['package']['bundle_sha256']
if mode=='resume':
    if not path.is_file(): raise SystemExit('No previous build24 review client. Run work first; no client data was reset.')
    value=json.loads(path.read_text())
    assert value.get('schema_version')==1 and value.get('device')==device and value.get('package_sha256')==fingerprint,'The saved review belongs to another device/package; use its original candidate or start work explicitly'
    store=str(uuid.UUID(value['store']))
else:
    store=str(uuid.uuid4())
    value={'schema_version':1,'device':device,'package_sha256':fingerprint,'store':store,'scenario':'p0-ui-accepted-work','port':8767}
    temporary=path.with_suffix('.json.writing');temporary.write_text(json.dumps(value,sort_keys=True,indent=2)+'\n');os.replace(temporary,path)
print(store)
PY
)"
if [[ "$device_state" != Booted ]]; then /usr/bin/xcrun simctl boot "$device"; fi
/usr/bin/xcrun simctl bootstatus "$device" -b
/usr/bin/xcrun simctl ui "$device" content_size "$text_size"
/usr/bin/xcrun simctl install "$device" "$app"
"${clean_launch[@]}" \
  SIMCTL_CHILD_CF_UI_TEST_STORE="$store" SIMCTL_CHILD_CF_UI_TEST_SCENARIO=p0-ui-accepted-work \
  SIMCTL_CHILD_CATPAW_ACCEPTED_WORK_PORT=8767 \
  /usr/bin/xcrun simctl launch --terminate-running-process "$device" com.example.CatpawM.ConversationFirst.Auth
open -b com.apple.dt.Devices
print "build24 — $mode review; real system text size: $text_size. No message was prefilled or sent."
print '1. Enter a fictional request, open input details, then choose “交给 Agent 完成 / Let Agent complete this”.'
print '2. Review the original text, scope, deadline and budgets; close and reopen to check they remain unchanged.'
print '3. Confirm the work, then explicitly allow the synthetic conversation-processing notice.'
print '4. Wait for the plan/report, expand the work card, and open the original report.'
print '5. Run this script with resume to reopen the same local client and check the original work and terms.'
print 'Boundary: real native App and maintained HTTP API; synthetic identity, scripted model and serialized test database. This is not real Agent/model/cloud/OS acceptance. Existing server snapshots, original work deadlines and client data are preserved.'
