# Changelog

All notable changes to this project are documented in this file.
The format is based on Keep a Changelog, and this project uses Semantic Versioning.

## [1.0.0] - 2026-10-17

### Added
- First-run transition E (plush cat hero, CTA morphs into composer, staggered rise; Reduce Motion fade); shown on first install only.
- Starter prompts on the empty conversation (tap sends immediately).
- GitHub and Google sign-in (Supabase PKCE) with trial-account identity linking.
- iOS: quiet, capped retry (≤5, same Idempotency-Key, honours Retry-After) on 503 `chat_runtime_busy`.

### Fixed
- No blocking white loader on subsequent launches; app opens straight into chat.
- `proactive.feedback.kind` accepts `intrusive` (migration 20261017050000); 「打扰到我」 no longer returns 500.
- Chat runtime lease released for turns rejected before the model call (403/409/422); `chat_runtime_busy` is now retryable with `Retry-After`.
- First-run contrast in Dark Mode; no orange text.

### Deployed
- catpaw-api v48 (792587e), catpaw-proactive v9, 9 migrations. Lock fix e9383ca pending deploy.

### Known issues
- APNs secrets incomplete (`/health` apns:false); proactive data in plaintext UserDefaults; Sign in with Apple deferred to v1.1.
