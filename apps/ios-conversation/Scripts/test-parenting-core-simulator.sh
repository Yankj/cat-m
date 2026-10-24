#!/usr/bin/env bash
# Run parenting module tests and UI journeys on a fresh simulator, using installed runtimes.
set -euo pipefail
cd "$(dirname "$0")/.."

# A configured developer build can contact its backend at launch. This CI lane uses no local config.
if [[ -e Configuration/Local.xcconfig ]]; then
  echo "Refusing synthetic parenting tests with a local backend configuration." >&2
  exit 1
fi

# These settings are only for this Simulator test lane; no device team/profile or production setting is changed.
parenting_derived_data="$PWD/../../build/parenting-core/SimulatorSigningDerivedData"
parenting_signing=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  "CODE_SIGN_ENTITLEMENTS=$PWD/Configuration/SimulatorFixtureAcceptance.entitlements"
)
# test-without-building cannot sign an old unsigned product. Require the matching fresh build first.
python3 -I - "$parenting_derived_data" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

EXPECTED_BUNDLE = "com.example.CatpawM.ConversationFirst.Auth"

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)

def validate_pair(info, entitlements):
    assert isinstance(info, dict) and isinstance(entitlements, dict), "Expected app and entitlement dictionaries"
    bundle = info.get("CFBundleIdentifier")
    assert bundle == EXPECTED_BUNDLE, "Unexpected main App bundle identity"
    assert info.get("CFBundlePackageType") == "APPL" and info.get("CFBundleExecutable") == "cat", "Expected the main cat App, not a test runner or Widget"
    assert info.get("CFBundleSupportedPlatforms") == ["iPhoneSimulator"], "Simulator artifacts only"
    assert all("$(" not in value and "$" + "{" not in value for value in strings(entitlements)), "Unexpanded entitlement placeholder"
    app_id = entitlements.get("application-identifier")
    assert isinstance(app_id, str) and app_id and not any(c.isspace() for c in app_id) and "*" not in app_id, "Invalid application identifier"
    assert app_id == bundle or app_id.endswith("." + bundle), "Entitlements do not belong to the actual main App"
    assert entitlements.get("keychain-access-groups") == [app_id], "Expected exactly the main App's Keychain group"
    assert entitlements.get("com.apple.developer.team-identifier", "") == "", "This local ad-hoc lane must not inherit a development team"
    return bundle

root = Path(sys.argv[1]).resolve()
app = root / "Build/Products/Debug-iphonesimulator/cat.app"
# Verify the main target's exact generated file; never accept a runner/Widget's first matching xcent.
xcent = root / "Build/Intermediates.noindex/cat.build/Debug-iphonesimulator/cat.build/cat.app-Simulated.xcent"
info = plistlib.loads((app / "Info.plist").read_bytes())
entitlements = plistlib.loads(xcent.read_bytes())
bundle = validate_pair(info, entitlements)
assert (app / info["CFBundleExecutable"]).is_file(), "Main App executable missing"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
signature = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)],
                           check=True, capture_output=True, text=True)
assert "Signature=adhoc" in signature.stdout + signature.stderr, "Expected Xcode-generated local ad-hoc signing"
print("PASS main Simulator App signature and generated identifiers/Keychain group; runtime Keychain tests still required")
PY

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
  xcodebuild -project cat.xcodeproj -scheme cat -configuration Debug -sdk iphonesimulator \
    -derivedDataPath "$parenting_derived_data" \
    -destination "platform=iOS Simulator,id=$parenting_simulator_id" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:catTests/ParentingWorkspaceTests \
    -only-testing:catTests/ParentingArrangementEditTests \
    -only-testing:catTests/ParentingRescheduleIntakeTests \
    -only-testing:catTests/ParentingIntakeTests \
    -only-testing:catTests/ParentingInlineIntakeTests \
    -only-testing:catTests/ParentingAccountLifecycleTests \
    -only-testing:catTests/ParentingReminderPlannerTests \
    -only-testing:catTests/ParentingReminderSchedulerTests \
    -only-testing:catTests/ParentingReminderModelTests \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testActiveKnownRotationRecoversAutomaticallyInSameLocalChat \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testWorkspace503RetriesSilentlyAndCoalescesUntilSuccess \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testReturningLocalChatStaysReadableAndForegroundWakesRetryInPlace \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testReachabilityAndLogoutFenceWorkspaceResolution \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testLogoutDuringFirstLocalReadNeverAttachesOldChat \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testLogoutCancelsOfflineRecoveryTaskBeforeNetworkReturns \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testLogoutClosesAuthorityBeforeLocalDrainAndLaterLoginStillOpens \
    -only-testing:catTests/NativeAuthApplicationLifecycleTests/testColdValidationRetriesSafelyWithoutCreatingAnotherIdentity \
    -only-testing:catUITests/ParentingWorkspaceUITests \
    test-without-building "${parenting_signing[@]}"
