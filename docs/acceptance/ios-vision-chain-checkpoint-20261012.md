# Native vision chain code checkpoint

2026-10-12, based on b6ad8d6. This is a reviewable source checkpoint. Full installation acceptance is BLOCKED. Current progress is maintained only in master-plan.md.

Implemented in the same host: independent image consent with a default-unchecked non-sensitive confirmation; exact conversation/preview hash+ID/caption/route/revision/scene fences; explicit Send after approval. Cancellation, changed drafts, scene suspension and late grants cannot start image transmission.

The v2 HTTP body carries one normalized image with nonempty text. Preflight reads current capability, text consent and the exact image consent revision. An unavailable image route blocks transmission without text fallback. Admission and terminal provider receipts must match attachment IDs/hash/bytes, fixed Gemma/Google route and zero cost. EOF or bad receipt preserves unknown and reads the original turn.

Image bytes live in an account-partitioned, backup-excluded, iOS-protected local vault; queue/journal encode metadata only. Queue save failure preserves input and removes staged bytes before any provider call. Unknown/failed/unsent requests can restore their local image; completed requests clean up transport bytes. Original operation IDs and observer fences remain intact.

## Actual evidence

Xcode27.1 / iOS SDK27.1 / dedicated iPhone17 Simulator iOS27.0. Latest Swift sources compiled and XCTest passed 40/40 with zero failures, including 9 new vision boundary cases: cancel/unconfirmed checkbox, precise approval and terminal metadata, expired consent refusal, late grant after draft changes, malformed image, save rollback, logical background resume without second POST, wrong provider receipt and local byte-vault restart/scope rejection. One historical Keychain entitlement test remains excluded.

This run uses an explicitly injected offline backend. Its POST counters are synthetic; there is no HTTP/Auth/model call. Raw xcresult: apps/ios-conversation/.build-ios/Vision-domain-checkpoint.xcresult. Hashes: evidence/ios-vision-chain-checkpoint-20261012/RESULT.json. The older b4850eb UI evidence does not prove this new image permission/Send UI.

19 new image UI/Picker bilingual entries were added after the logic run. Actual localization gate remains FAIL97 owned literals and zero missing lookup resources. These are real locale-binding gaps in login/conversation/settings, not merely false alarms; no exemption was widened. English UI has not been accepted.

## Remaining release conditions

1. Actual native HTTP v2 synthetic wire validation, and actual PhotosPicker/permission/Send UI actions on this source. HTTP-v2 code compiled, but the tests above inject the backend.
2. Actual Simulator Home5s/30s, retained drafts/images and original-turn cursor/call counts. Current suspend/resume is logic evidence; full App cold restart is not tested.
3. Main-flow localization, reading-anchor protection, physical presented frames, real Chinese IME, VoiceOver and weak-network checks.
4. Live flag enabled and actual image capability available, followed by the normal authenticated App flow with a dedicated synthetic image: provider/image hash/zero-cost/terminal receipts plus blind pixel semantics and a follow-up. Coordinator reports v18 vision disabled; this task made no production call or credential export.
5. Same final native/API source, signed binary/build/install identity and all six release groups. No phone overwrite, deployment, push, new identity or model/tick request occurred here.
