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
