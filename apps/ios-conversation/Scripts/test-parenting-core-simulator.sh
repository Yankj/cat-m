#!/usr/bin/env bash
# Run only the parenting synthetic XCTest classes on a fresh simulator, using installed runtimes.
set -euo pipefail
cd "$(dirname "$0")/.."

# A configured developer build can contact its backend at launch. This CI lane uses no local config.
if [[ -e Configuration/Local.xcconfig ]]; then
  echo "Refusing synthetic parenting tests with a local backend configuration." >&2
  exit 1
fi

IFS=$'\t' read -r parenting_device_type parenting_runtime < <(
  xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
choices = [(runtime, d["name"], d["deviceTypeIdentifier"])
           for runtime, group in devices.items() if ".iOS-" in runtime
           for d in group if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not choices:
    sys.exit("No installed available iPhone simulator runtime; no downloads will be attempted.")
runtime, _, kind = sorted(choices, reverse=True)[0]
print(kind + "\t" + runtime)
'
)
parenting_simulator_id="$(xcrun simctl create "mimi-parenting-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}" "$parenting_device_type" "$parenting_runtime")"
trap 'xcrun simctl shutdown "$parenting_simulator_id" >/dev/null 2>&1 || true; xcrun simctl delete "$parenting_simulator_id" >/dev/null 2>&1 || true' EXIT

# Do not inherit a developer's alternate fixture/connection or simulator-child injection.
for parenting_env_key in $(compgen -e); do
  case "$parenting_env_key" in
    SIMCTL_CHILD_*|CF_UI_*|R7_SYNTHETIC_CONNECTION_B64URL|R7_AUTH_TEST_*) unset "$parenting_env_key" ;;
  esac
done

env -u CATPAW_SUPABASE_PROJECT_URL -u CATPAW_SUPABASE_PUBLISHABLE_KEY \
  -u CATPAW_BACKEND_ORIGIN -u CATPAW_SERVER_SCOPE_ID \
  xcodebuild -project cat.xcodeproj -scheme cat \
    -destination "platform=iOS Simulator,id=$parenting_simulator_id" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:catTests/ParentingWorkspaceTests \
    -only-testing:catTests/ParentingIntakeTests \
    -only-testing:catTests/ParentingInlineIntakeTests \
    test-without-building CODE_SIGNING_ALLOWED=NO
