#!/bin/zsh
# Explicit offline native review. Never logs into Supabase or invokes a model.
set -eu
cd "$(dirname "$0")/../../.."
mode="${1:-report}"
device="${CATPAW_REVIEW_DEVICE:-949DAB72-1A93-4ECF-86E3-2E487B25C27E}"
app="build/typography-trial-20261014/DerivedData/Build/Products/Debug-iphonesimulator/CatpawM.app"
case "$mode" in
  input) scenario=p0-ui-echo ;;
  plan) scenario=p0-ui-plan ;;
  report) scenario=p0-ui-artifact-edit ;;
  approval) scenario=p0-ui-task-action ;;
  control) scenario=p0-ui-task-control ;;
  calculator) scenario=p0-ui-genui ;;
  normal) scenario='' ;;
  *) print -u2 'Usage: zsh apps/ios-conversation/Scripts/run-simulator-review.sh [input|plan|report|approval|control|calculator|normal]'; exit 2 ;;
esac
[[ -d "$app" ]] || { print -u2 'Build23 Simulator package is absent. See the build23 acceptance record.'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" == 23 ]] || { print -u2 'Expected build23; refusing an ambiguous package.'; exit 1; }
/usr/bin/python3 - "$app/Info.plist" <<'PY'
import hashlib,json,plistlib,sys
from pathlib import Path
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
assert info.get('CFBundleIdentifier')=='com.example.CatpawM.ConversationFirst.Auth','Unexpected review bundle identity'
keys=('CatpawSupabaseProjectURL','CatpawSupabasePublishableKey','CatpawBackendOrigin','CatpawServerScopeID','CatpawEdgeRegion')
assert not any(info.get(k) for k in keys),'Offline review refuses a cloud-configured package'
package=Path(sys.argv[1]).parent
rows=[{'path':str(p.relative_to(package)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(package.rglob('*')) if p.is_file()]
fingerprint=hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(',',':')).encode()).hexdigest()
expected=json.loads(Path('docs/acceptance/evidence/native-typography-20261014/RESULT.json').read_text())['package']['bundle_sha256']
assert fingerprint==expected,'Review package differs from the accepted offline candidate'
PY
# Clear every inherited simulator child variable, including all R7/R9 fixtures.
# Only the explicitly selected offline P0 scenario is added below.
clean_launch=(env)
for key in ${(k)parameters}; do
  if [[ "$key" == SIMCTL_CHILD_* ]]; then clean_launch+=(-u "$key"); fi
done
# Use an existing, available device only. No create, erase, uninstall or data reset.
device_state="$(/usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); matches=[x for xs in d["devices"].values() for x in xs if x["udid"]==sys.argv[1]]; assert len(matches)==1,"Requested existing device is unavailable"; print(matches[0]["state"])' "$device")"
if [[ "$device_state" != Booted ]]; then /usr/bin/xcrun simctl boot "$device"; fi
/usr/bin/xcrun simctl bootstatus "$device" -b
/usr/bin/xcrun simctl ui "$device" content_size large
/usr/bin/xcrun simctl install "$device" "$app"
if [[ -n "$scenario" ]]; then
  store="$(/usr/bin/uuidgen)"
  "${clean_launch[@]}" \
    SIMCTL_CHILD_CF_UI_TEST_STORE="$store" SIMCTL_CHILD_CF_UI_TEST_SCENARIO="$scenario" \
    /usr/bin/xcrun simctl launch --terminate-running-process "$device" com.example.CatpawM.ConversationFirst.Auth
  print "build23 — explicit offline $mode review, default system text size. Send a short local message to reveal the native flow. Simulated receipts and sources are not real Agent results."
else
  "${clean_launch[@]}" \
    /usr/bin/xcrun simctl launch --terminate-running-process "$device" com.example.CatpawM.ConversationFirst.Auth
  print 'build23 — normal launch, no fixture. This review package has no cloud configuration.'
fi
# Xcode 27 uses Device Hub for simulator windows. A locked Mac needs manual unlock.
open -b com.apple.dt.Devices
