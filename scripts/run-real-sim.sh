#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

required=(
  CATPAW_SUPABASE_PROJECT_URL
  CATPAW_SUPABASE_PUBLISHABLE_KEY
  CATPAW_BACKEND_ORIGIN
)
missing=()
for name in "${required[@]}"; do
  [[ -n "${(P)name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
  print -u2 "Missing required environment variable(s): ${(j:, :)missing}"
  exit 2
fi

device="9A4BC49A-CCE4-45D6-A1DC-6F072236DAB6"
derived_data="/tmp/catpaw-dd-merge"
app="$derived_data/Build/Products/Debug-iphonesimulator/cat.app"
bundle_id="com.example.cat.ConversationFirst.Auth"

device_state="$(/usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); matches=[item for devices in data["devices"].values() for item in devices if item["udid"]==sys.argv[1]]; assert len(matches)==1,"Requested simulator is unavailable"; print(matches[0]["state"])' "$device")"
if [[ "$device_state" != Booted ]]; then
  /usr/bin/xcrun simctl boot "$device"
fi
/usr/bin/xcrun simctl bootstatus "$device" -b

/usr/bin/xcodebuild \
  -project apps/ios-conversation/cat.xcodeproj \
  -scheme cat \
  -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$derived_data" \
  build

[[ -d "$app" ]] || { print -u2 'Debug simulator app was not produced at the expected path.'; exit 1; }
if /usr/bin/xcrun simctl get_app_container "$device" "$bundle_id" app >/dev/null 2>&1; then
  /usr/bin/xcrun simctl uninstall "$device" "$bundle_id"
fi
/usr/bin/xcrun simctl install "$device" "$app"

# Prevent unrelated fixture variables inherited by this shell from reaching the app.
clean_launch=(env)
for name in ${(k)parameters}; do
  if [[ "$name" == SIMCTL_CHILD_* ]]; then clean_launch+=(-u "$name"); fi
done
"${clean_launch[@]}" \
  SIMCTL_CHILD_CATPAW_SUPABASE_PROJECT_URL="$CATPAW_SUPABASE_PROJECT_URL" \
  SIMCTL_CHILD_CATPAW_SUPABASE_PUBLISHABLE_KEY="$CATPAW_SUPABASE_PUBLISHABLE_KEY" \
  SIMCTL_CHILD_CATPAW_BACKEND_ORIGIN="$CATPAW_BACKEND_ORIGIN" \
  /usr/bin/xcrun simctl launch --terminate-running-process "$device" "$bundle_id"

open -b com.apple.dt.Devices
