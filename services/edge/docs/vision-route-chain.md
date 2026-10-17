# Vision route: free chain (image-upload-bug, 2026-10-17)

`CATPAW_VISION_ROUTE` = `chain` (default) | `legacy`. `chain` applies only when the Gemini key is deployed with the
interactions protocol and `CATPAW_GEMINI_ROUTE` is not `off`. In every other case, including an unknown value,
`legacy` is used.

| mode | order | image `route_hash` | consent text |
|---|---|---|---|
| `chain` | Gemini API free tier `gemini-3.5-flash-lite` → OpenRouter `google/gemma-4-31b-it:free` (Google AI Studio) | `VISION_CHAIN_ROUTE_HASH` (6e430e58…) | `VISION_CHAIN_CONSENT_UI` |
| `legacy` | OpenRouter Gemma 4 only (unchanged) | `LIVE_VISION_ROUTE_HASH` (3665b04e…) | `VISION_CONSENT_UI` |

- The chain fails over only before any output, and only on busy or unavailable codes or on a failure that is not
  ambiguous. A turn whose dispatch is uncertain (reconciliation) is never resent to the second provider.
- The Gemini model is pinned in the consented route. It is **not** added to `CATPAW_GEMINI_MODELS`, so the text/account
  consent `route_hash` does not change.
- Image consent is per conversation and bound to the image `route_hash`. With `chain`, each conversation asks once more
  before its next image (`provider_image_consent_required`). Switching back to `legacy` makes the old consents valid again.
- Gemini's local guard keeps the RPM window and the cooldown **per model**. Vision Flash-Lite and text Flash-Lite share one
  model quota (one Google project); a strong model hitting its daily quota no longer pauses the others.
- `rate_limited` always carries an advisory delay. HTTP errors send the `Retry-After` header and
  `error.retry_after_seconds`. SSE `turn_failed` sends `retry_after_seconds`. The delay is an integer from 1 to 3600 and
  comes from the provider header, Google RetryInfo, or the OpenRouter daily reset (capped at 1 h), with 30 s as the default.
- Logs: `catpaw_route_attempt` with `route: "vision-gemini" | "vision-openrouter"`.
- r2 (NoBug review fixes): both hops are declared and enforced as `tools:'none'` (the chain always sends `tools:[]`).
  A Gemini key, config, or request fault (`unauthorized`, `forbidden`, `provider_request_invalid`,
  `free_model_unavailable`, …) still falls back to Gemma for the user, but it is logged as
  `failure_class:"provider_config_error"` plus a `catpaw_vision_route_config_error` warning. Gemini failure evidence on
  image turns keeps only the classification fields. `/readyz` shows `vision_route:{mode,route_hash}`.
