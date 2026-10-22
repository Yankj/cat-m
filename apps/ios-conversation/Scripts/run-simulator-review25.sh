#!/bin/zsh
# Fixed build25; reuses only the existing synthetic memory-normal-r3 server.
# No server start/renewal, automatic UI clicks, text, consent or POST.
set -euo pipefail
cd "${0:A:h}/../../.."
mode="${1:-resume}"
(( $# <= 1 )) || { print -u2 'Expected only work or resume.'; exit 2; }
case "$mode" in work|resume) ;; *) print -u2 'Usage: zsh apps/ios-conversation/Scripts/run-simulator-review25.sh [work|resume]'; exit 2 ;; esac
device=BE5C60E0-B415-4BF4-8F36-8975FB5314AA
[[ "${CATPAW_REVIEW_DEVICE:-$device}" == "$device" ]] || { print -u2 'build25 is pinned to its existing Simulator; no other device will be used.'; exit 2; }
text_size="${CATPAW_REVIEW_TEXT_SIZE:-large}"
case "$text_size" in
  extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large) ;;
  *) print -u2 'CATPAW_REVIEW_TEXT_SIZE must be a supported simctl content_size value.'; exit 2 ;;
esac
app=build/native-memory-20261015/DerivedData/Build/Products/Debug-iphonesimulator/cat.app
# Unset every inherited Simulator child override before any simctl command.
clean=(/usr/bin/env)
for key in ${(k)parameters}; do
  if [[ "$key" == SIMCTL_CHILD_* ]]; then clean+=(-u "$key"); fi
done
store="$(/usr/bin/python3 - "$mode" "$device" "$app" <<'PY'
import datetime,hashlib,json,os,plistlib,shlex,subprocess,sys,time,urllib.request,uuid
from pathlib import Path
mode,device,app=sys.argv[1:]
root=Path.cwd();package=root/app
expected='7bbf2741c12ddf7753f665d210513c3efd009af75bb6b6ba1422b4300a92138b'
origin='http://127.0.0.1:8769'
scope='51000000-0000-4000-8000-000000000001';subject='51000000-0000-4000-8000-000000000004';session_id='51000000-0000-4000-8000-000000000005'
state_path=root/'services/edge/build/native-accepted-work-20261015/memory-normal-r3.json'
script=root/'services/edge/test/fixtures/native-accepted-work-server.mjs'
# This is the original session expiry in normal-r3, not a moving six-hour window.
original_expiry=1792049410
route_hash='ff91db5a87dd3885936c92fe8ef7b917d4e643fe0198e3a7509405d7e389629f'
def require(condition,message):
    if not condition: raise SystemExit(message+' No service, authorization or user data was reset.')
def unique(pairs):
    result={}
    for key,value in pairs:
        require(key not in result,'Duplicate metadata field.')
        result[key]=value
    return result
def decode(data):return json.loads(data,object_pairs_hook=unique)
require((package/'Info.plist').is_file(),'Fixed build25 package is absent; nothing was installed.')
info=plistlib.loads((package/'Info.plist').read_bytes())
require(info.get('CFBundleVersion')=='25' and info.get('CFBundleIdentifier')=='com.example.cat.ConversationFirst.Auth' and info.get('DTPlatformName')=='iphonesimulator','Expected the fixed build25 Simulator identity.')
require(not any(key in info for key in ('CatpawSupabaseProjectURL','CatpawSupabasePublishableKey','CatpawBackendOrigin','CatpawServerScopeID','CatpawEdgeRegion')),'A cloud-configured package cannot be used for this review.')
require(not any(p.is_symlink() for p in package.rglob('*')),'Package symlinks are not part of the fixed review.')
rows=[{'path':str(p.relative_to(package)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(package.rglob('*')) if p.is_file()]
fingerprint=hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(',',':')).encode()).hexdigest()
require(len(rows)==30 and fingerprint==expected,'Package differs from the pinned 30-file build25 candidate.')
# Verify the listening process, not just a compatible-looking HTTP response.
try:
    pids=subprocess.check_output(['/usr/sbin/lsof','-nP','-iTCP@127.0.0.1:8769','-sTCP:LISTEN','-t'],text=True,stderr=subprocess.DEVNULL,timeout=3).split()
    require(len(set(pids))==1,'Port8769 is absent or ambiguous; ask Root to restore its existing reviewed service.')
    argv=shlex.split(subprocess.check_output(['/bin/ps','-p',pids[0],'-o','command='],text=True,timeout=3))
    require(any(Path(arg).resolve()==script for arg in argv) and '--port=8769' in argv and '--mode=normal' in argv and any(arg.startswith('--state=') and Path(arg[8:]).resolve()==state_path for arg in argv),'Port8769 is not the exact existing memory-normal-r3 service.')
except (OSError,subprocess.SubprocessError,ValueError) as error:
    raise SystemExit('Cannot verify the existing port8769 process. Nothing was started or stopped; ask Root to inspect it.') from error
require(state_path.is_file(),'The original memory-normal-r3 snapshot is absent.')
state=decode(state_path.read_bytes())
require(state.get('fixture_kind')=='actual_cloud_native_loopback_v1' and state.get('version')==1 and state.get('mode')=='normal' and state.get('origin')==origin and state.get('subject_id')==subject and state.get('scope',{}).get('scope_id')==scope,'Original snapshot identity does not match this review.')
records={tuple(json.loads(key)):value for key,value in state['repository']['records']}
sessions=[value for key,value in records.items() if len(key)==3 and key[1]=='app-sessions' and key[2]==session_id]
members=[value for key,value in records.items() if len(key)==3 and key[1]=='scope-memberships' and key[2]==subject]
require(len(sessions)==1 and sessions[0].get('subject_id')==subject and sessions[0].get('state')=='active' and sessions[0].get('expires_at')==original_expiry,'The original synthetic session changed, was revoked, or was renewed; refusing to replace its authority.')
require(time.time()<original_expiry,'The original synthetic session expired; this script cannot create or renew authorization.')
require(len(members)==1 and members[0].get('state')=='active' and members[0].get('tokens_valid_after',2)<=1 and session_id not in members[0].get('revoked_session_ids',[]) and any(row.get('scope_id')==scope for row in members[0].get('scopes',[])),'Original synthetic membership is no longer active.')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise RuntimeError('Loopback redirect refused')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
def get(path,authorized=False):
    headers={'Accept':'application/json'}
    if authorized:headers['Authorization']='Bearer native-wire-offline'
    with opener.open(urllib.request.Request(origin+path,headers=headers,method='GET'),timeout=3) as response:
        require(response.status==200 and response.headers.get_content_type()=='application/json','Existing fixture rejected read-only verification.')
        data=response.read(2_000_001)
    require(len(data)<=2_000_000,'Fixture response exceeds the review limit.')
    return decode(data)
try:
    metadata=get('/testing/v1/fixture');provenance=metadata.get('provenance',{});window=metadata.get('synthetic_viewer_window',{})
    require(metadata.get('fixture_kind')=='actual_cloud_native_loopback_v1' and metadata.get('mode')=='normal' and metadata.get('origin')==origin and metadata.get('subject_id')==subject and metadata.get('scope',{}).get('scope_id')==scope and metadata.get('route_hash')==route_hash and metadata.get('authentication')=='explicit_test_fixture_session' and metadata.get('model_reality')=='injected_synthetic_fixture' and metadata.get('real_supabase_login_verified') is False and all(provenance.get(key) is False for key in ('real_auth','real_model','real_sql')) and window.get('new_snapshot_session_lifetime_seconds')==21600 and window.get('restored_snapshot') is True and window.get('restore_preserves_original_expiry') is True and window.get('extends_work_grant') is False,'Port8769 has incompatible fixture metadata; it will not be reused.')
    memory=get('/catpaw/memory/v1/scopes/'+scope+'/state',authorized=True)
    require(memory.get('schema_version')==1 and memory.get('contract')=='catpaw.memory.v1' and memory.get('scope_id')==scope and memory.get('subject_id')==subject,'The existing original session cannot read its actual scoped memory.')
except Exception as error:
    raise SystemExit('Read-only verification of the existing synthetic session failed. No authorization was created, renewed, or replaced.') from error
local=root/'build/native-memory-20261015';client_path=local/'review-client25.json'
binding={'schema_version':1,'device':device,'package_sha256':expected,'scenario':'p0-ui-accepted-work','port':8769,'scope_id':scope,'subject_id':subject,'session_expires_at':original_expiry}
client=decode(client_path.read_bytes()) if client_path.is_file() else None
if client is not None:require(all(client.get(key)==value for key,value in binding.items()) and isinstance(client.get('stores'),list),'Saved review client belongs to a different candidate/session/device.')
if mode=='resume':
    require(client is not None,'No saved build25 client exists; run work explicitly first.')
    store=str(uuid.UUID(client['store']));require(store in client['stores'],'Saved client identity is inconsistent.')
else:
    store=str(uuid.uuid4());stores=list(client['stores']) if client else [];stores.append(store)
    client={**binding,'store':store,'stores':stores}
    local.mkdir(parents=True,exist_ok=True);temporary=client_path.with_suffix('.json.writing');temporary.write_text(json.dumps(client,sort_keys=True,indent=2)+'\n');os.replace(temporary,client_path)
expiry=datetime.datetime.fromtimestamp(original_expiry,datetime.timezone.utc).isoformat()
print('Verified fixed build25 / existing normal-r3; original session expires '+expiry+'.',file=sys.stderr)
print('Read-only counters before launch: '+json.dumps({key:metadata.get('counters',{}).get(key) for key in ('memory_posts','provider_calls')},sort_keys=True),file=sys.stderr)
print(store)
PY
)"
# Existing device only; never create, erase, uninstall or touch the build24 device.
device_state="$("${clean[@]}" /usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; matches=[d for rows in json.load(sys.stdin)["devices"].values() for d in rows if d["udid"]==sys.argv[1]]; assert len(matches)==1,"Pinned existing build25 Simulator unavailable"; print(matches[0]["state"])' "$device")"
if [[ "$device_state" != Booted ]]; then "${clean[@]}" /usr/bin/xcrun simctl boot "$device"; fi
"${clean[@]}" /usr/bin/xcrun simctl bootstatus "$device" -b
"${clean[@]}" /usr/bin/xcrun simctl ui "$device" content_size "$text_size"
installed="$("${clean[@]}" /usr/bin/xcrun simctl get_app_container "$device" com.example.cat.ConversationFirst.Auth app 2>/dev/null)" || installed=''
if [[ -n "$installed" ]] && /usr/bin/python3 - "$installed" <<'PYVERIFY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);rows=[{'path':str(p.relative_to(root)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.rglob('*')) if p.is_file()]
valid=len(rows)==30 and not any(p.is_symlink() for p in root.rglob('*')) and hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(',',':')).encode()).hexdigest()=='7bbf2741c12ddf7753f665d210513c3efd009af75bb6b6ba1422b4300a92138b'
sys.exit(0 if valid else 1)
PYVERIFY
then
  print 'Installed build25 bytes already match; reusing the existing installation.'
else
  "${clean[@]}" /usr/bin/xcrun simctl install "$device" "$app"
fi
"${clean[@]}" SIMCTL_CHILD_CF_UI_TEST_STORE="$store" SIMCTL_CHILD_CF_UI_TEST_SCENARIO=p0-ui-accepted-work SIMCTL_CHILD_CATPAW_ACCEPTED_WORK_PORT=8769 /usr/bin/xcrun simctl launch --terminate-running-process "$device" com.example.cat.ConversationFirst.Auth
/usr/bin/open -b com.apple.dt.Devices
print "build25 — $mode; real system text size: $text_size; local client: $store"
print '1. In the App, open the menu, then Memory / 记忆. This fixed binary has no automatic memory deep-link.'
print '2. Inspect current memory and source references; leave drafts unsubmitted for this read-only launch check.'
print '3. Run this script with resume to return to the same client. Work creates another local QA client and retains all prior clients.'
print 'Nothing was typed, confirmed or posted by this script. Enabling, saving, correcting and forgetting each require your explicit review in the App.'
print 'Boundary: native App + maintained loopback HTTP; synthetic identity, injected model and serialized test database. No real Auth/model/SQL/phone acceptance; no service start, expiry extension, reset or build24 device/port change.'
