# Workspace connection recovery

Implementation on `fix/workspace-connect`, 2026-10-16. Continued the existing auth WIP; the existing PRD edit is preserved outside this commit. No PRD or design document was written.

## Root cause

The account bootstrap chain is launch → `NativeAuthApplicationModel` → Supabase session restore → `GET /catpaw/account/v1/session` → Edge `authenticate` → `createSupabaseTokenVerifier` → Supabase JWKS → official user verification → scoped workspace mapping.

`auth_key_service_unavailable` is generated in `services/edge/supabase/functions/_shared/core/src/supabase-auth.mjs` when the remote JWKS fetch times out (5 seconds). This failure happens before workspace authorization; it does not prove the saved session is invalid. The client previously treated workspace discovery as a one-shot operation, exposed HTTP/code details, and depended on another entrance tap to retry. Other JWKS fetch/HTTP/JSON failures and official-user availability failures could also be misclassified as invalid sessions.

The separate “已有会话未能安全恢复” path protects a refresh token whose rotation outcome is unknown. That barrier must remain closed. However, a successfully received new token followed by a temporary read-only user-validation failure can recover safely; previously that known result was discarded or stranded.

These are source-traced causes and offline reproductions. Production connectivity was not probed, so the infrastructure reason for the reported JWKS timeout remains unverified.

## Implemented behavior

- Launch uses the existing prewarm hook without changing launch/onboarding layout, animation, assets or timing.
- One workspace discovery flight per account generation; transient transport, 408, 429 and 5xx failures retry silently with jittered 1/2/4/8/16-second backoff capped at 16 seconds. Offline waits suspend attempts; reachability and foreground events wake recovery.
- Returning local conversations remain readable with network admission closed until identity and workspace validation succeed. Recovery admits the same local partition in place.
- Known signup/rotation results retry only user validation. Unknown rotations, logout, cancellation, rejected identities and storage failures cannot silently grant authority, create replacement identities, or replay messages/consents/effects.
- Terminal failures use friendly localized copy and an explicit restart action. Transient snapshot messages no longer leak into onboarding. Existing chat error presentation also receives terminal recovery failures.
- Edge keeps JWT verification fail-closed while returning 503 for JWKS and official-user service availability failures. Invalid signatures, foreign issuers, expired JWTs and unknown signing keys remain rejected. Existing issuer, algorithm, scope and anonymous-project restrictions are preserved.
- Auth regression scripts now include the existing conversation dependencies referenced by their shared test support; no dependency was added.

## Verification

- Xcode 27.1 / iOS Simulator SDK 27.1: unsigned `CatpawM` Debug `build-for-testing` succeeded for arm64 and x86_64, including the host and regression targets. Command: `xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj -scheme CatpawM -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/workspace-connect/DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build-for-testing`.
- Portable auth: 24 assertions passed; anonymous/session recovery: 17 assertions passed. All use injected offline remotes.
- Actual Simulator XCTest: 17/17 passed (11 application lifecycle and 6 native auth tests), using a fresh offline fixture namespace on the existing QA simulator; the Keychain round-trip test was excluded. The initial run exposed the empty-vault offline startup wait and was interrupted; the corrected candidate was rebuilt and the complete selected suite passed in `NativeAuth-r2.xcresult`. The user's experience simulator was preserved.
- Edge auth: 11 tests passed with real local signing/verification and fake transports, including timeout, network failure, HTTP failure, invalid JSON/JWKS, recovery/cache behavior and rejected JWTs. The available preinstalled Node/Jose runtime is Node 22.17.1 / Jose 6.2.10; exact pinned Deno/Jose 6.2.12 execution was unavailable and is not claimed. No packages were installed.
- Logs and execution artifacts stay under ignored `build/workspace-connect/`.
- Non-DEBUG iOS SDK typecheck, project/localization gates, repository layout, frozen-source/contract integrity, deployed snapshot identity, sensitivity scan and `git diff --check` passed. Scan false positives were reviewed and pinned to exact bytes; no scanner rule was relaxed.

## Server action needed

No production action was performed. An operator should check Edge DNS/TLS/egress and availability for the configured project's `/auth/v1/.well-known/jwks.json` and `/auth/v1/user`, and confirm the existing project URL matches issued JWTs. Restore service reachability if the timeout persists; client retries cannot repair an unreachable server dependency.

The local Edge error-classification changes require a separately authorized, source-reconciled deployment before they affect the hosted API. This maintenance tree is not a replacement for both hosted API and tick snapshots. No secret change, provider switch or new compute is required by this patch. No deployment, phone installation, live Auth/model request, push or PR was performed.
# CatpawM widgets, notifications, and Live Activity report

Date: 2026-10-16 (Asia/Shanghai). This is dated implementation/build evidence; live project status remains in `docs/status/master-plan.md`.

## Source identity and scope

- Branch: `feat/widgets-notify`.
- Original slice base: `1632deb058fff4809453ef9b80eaf170647a4347`.
- Retained implementation: `437ee8a` (`feat(ios): polish widgets notifications and live activity`). This continuation reviewed that commit and completed the fixes below without rewriting history.
- Existing upstream remains `origin/feat/ios-mvp-integration-v2`; its five newer commits were not merged into this scoped change. No push or PR was performed.
- Compiled app version: `0.3.0 (39)`; no package was installed or shared.
- The pre-existing approved `.eden/quickstart/prd.md` modification was preserved and excluded from the commit.

## Delivered behavior

- Next-suggestion and next-meeting home widgets show a title and why line using the existing minimal App Group projection. Their deep links are `catpawm://proactive` and `catpawm://new` respectively. Compact meeting layouts put the time in the header to leave room for the title and reason.
- Lock Screen accessories use monochrome-compatible SF Symbols. Suggestions open the proactive inbox; meeting/empty continuation states open the new conversation route. Empty states do not claim completed work or knowledge of an unshared calendar.
- Version-2 snapshots decode defensively. Missing, corrupt, unsupported, oversized, stale, or invalid-date data produces truthful empty content. Meeting suggestions expire at their start; explicit timeline entries clear expired content even when refresh is deferred. The freshness limit is 24 hours, with a five-minute clock-skew allowance. Writes remain atomic and local.
- The retained Live Activity implementation replaces the illustrated mimi with warm off-white, orange accents, semantic status symbols/text, and a restrained phase track. Compact, minimal, and expanded Dynamic Island layouts retain their conversation links. Attributes, coordinator lifecycle, content-state contract, and token behavior were preserved.
- Create reminder, Snooze, and Not now call `ProactiveSuggestionStore.perform` and the existing `ProactiveSuggestionBackend`. Not now maps to dismiss. Create reminder brings the app foreground for normal permission handling; unknown and system-dismiss actions do not create effects. Existing remote categories and `/push/action` mapping remain intact.
- Pre-scheduled notification metadata now preserves the original reminder due time. Cold-start actions recover the stable local meeting suggestion without remote reevaluation or another notification. Dates and meeting identity are validated; busy, unavailable, or terminal actions are ignored. A late evaluation cannot replace a notification's newer inbox state. Default taps recover the suggestion before routing to the proactive inbox.

## Reviewed file set

Implementation across this slice:

- `apps/ios-conversation/Widgets/CatpawWidgets/CatpawHomeWidgets.swift`
- `apps/ios-conversation/Widgets/CatpawWidgets/CatpawWorkLiveActivity.swift` (retained from `437ee8a`)
- `apps/ios-conversation/Sources/App/CatpawPushNotifications.swift`
- `apps/ios-conversation/Sources/Features/Proactive/ProactiveEngine.swift` (notification recovery and existing snapshot seam)

Supporting changes:

- `apps/ios-conversation/Tests/WidgetNotificationSurfaceRunner.swift`
- `apps/ios-conversation/Scripts/test-widget-notification-surfaces.sh`
- `docs/status/master-plan.md` (required dated slice entry; long-term Goal remains paused)
- `CODEX_REPORT.md`

No backend, model route, Auth, conversation UI, package, historical app, entitlement, or Xcode project changes were made.

## Verification

PASS — final simulator build, including `CatpawWidgets.appex` embedded in the host:

```sh
xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj \
  -scheme CatpawM -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/catpawm-widgets-notify-20261016-dd \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `BUILD SUCCEEDED` (Xcode 27.1). Existing actor-isolation and deprecation warnings remain. The initial sandboxed attempt failed to access CoreSimulator/SwiftPM caches; authorized host execution passed without dependency installation.

PASS:

```sh
zsh apps/ios-conversation/Scripts/test-widget-notification-surfaces.sh
zsh apps/ios-conversation/Scripts/check-source.sh
python3 apps/ios-conversation/Scripts/app-version.py check --app /tmp/catpawm-widgets-notify-20261016-dd/Build/Products/Debug-iphonesimulator/CatpawM.app
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/check-deployed-source.py
git diff --check
```

The portable runner executes the actual snapshot decoder and notification metadata parser: 34 assertions covering valid/partial payloads, unsupported versions, corruption, stale and extreme dates, expiry ordering, original scheduled lead time, legacy defaults, and malformed notification context. It does not execute the notification delegate, backend actions, or OS effects. The source gate passed after host execution allowed Swift macro plugins; its sandbox-only macro failure is retained in the ignored log. Version readback passed `0.3.0 (39)`.

Sensitivity command: `python3 scripts/scan-repository.py`. Result: zero blocking hits; exit 1 for eight unchanged manual-review matches. Six are asset scale filenames, one is the repository SSH allowlist literal, and one is a synthetic test-key literal. All were read and confirmed as non-secret; no new match was introduced and the baseline was not modified.

Raw logs remain under ignored `build/widgets-notify-review/`: `xcodebuild-final.log`, `native-source-host.log`, `surface-tests.log`, `layout.log`, `integrity.log`, `deployed-source.log`, and `sensitivity.log`. Initial sandbox failures are kept separately.

## Final implementation SHA256

| Input | SHA256 |
|---|---|
| CatpawHomeWidgets.swift | `1319990ae60debd94dbcceafc9c2cc88e7812ef0d692dfe127c80ea63ecb436d` |
| CatpawWorkLiveActivity.swift | `9a8b59632708d15c80a679f10d53cfec9bc5fb7cc4338259ce9705447230530c` |
| CatpawPushNotifications.swift | `b22ec9df9f88e65a1f64d644a0b7f46d6a4a0346bed0b03ea307a48e90b258e0` |
| ProactiveEngine.swift | `db54a4cee8cc5c2095e96564895127ea9af750275e7aff27e2152e9d816d8c86` |
| test-widget-notification-surfaces.sh | `510c6a48cea587810ac83f994cbaefc46785aef55ac01b62ecae8b7661e6c25c` |
| WidgetNotificationSurfaceRunner.swift | `7a70dfdf4e39d79dd2db6f9f42edb97a90fc0c0fc058e35bc78d657623e23bac` |

## Evidence limits

- Compilation and synthetic parsing checks do not prove widget/Live Activity pixels, Dynamic Island layout, actual notification delivery/actions, EventKit reminder creation, VoiceOver, maximum Dynamic Type, or physical-device behavior. Those paths were not run.
- The existing App Group remains unprovisioned. Real cross-process sharing requires the valid shared entitlement/profile and separate system evidence; the extension intentionally shows empty content when sharing is unavailable.
- No permission prompt, device installation, model/Auth request, deployment, or server operation was executed. AF-A15, AF-A17, AF-U10–12, FINAL-G1, and FINAL-G3 remain unaccepted; the paused long-term Goal was not resumed.
