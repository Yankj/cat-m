# Model routes contract (`catpaw.model-routes.v1`)

Client-facing route list, route/model selection and per-turn route reporting. No secrets, no internal
base URLs are ever returned.

## 1. `GET /catpaw/model-routes/v1` (auth required, same Supabase JWT as chat)

```json
{
  "contract": "catpaw.model-routes.v1",
  "default_route": "auto",
  "primary_route": "gemini",
  "chain": ["gemini", "openrouter", "opencode", "agnes"],
  "auto_failover": true,
  "routes": [
    {
      "id": "gemini",
      "display_name": "Google Gemini",
      "models": [{ "id": "gemini-3.5-flash-lite", "default": true }],
      "status": "online",
      "last_error": { "code": "rate_limited", "at": "2026-10-16T08:01:02.000Z" },
      "cooling_seconds": 0,
      "free": true,
      "billing": "free_tier",
      "policy_url": "https://ai.google.dev/gemini-api/terms",
      "data_note": "free_tier_may_train"
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `routes[].id` | string | `openrouter` \| `gemini` \| `groq` \| `opencode` \| `agnes`. Only routes whose key is configured are listed. |
| `routes[].display_name` | string | Human label (e.g. `OpenCode Zen (free)`). |
| `routes[].models[]` | `{id, default}` | Allow-list accepted in `X-Catpaw-Model`. Default model first. |
| `routes[].status` | enum | `online` (configured, no recent error), `degraded` (last error newer than last success, within 5 min), `offline` (cooling down after 429/quota, or last 3 attempts failed). |
| `routes[].last_error` | object\|null | `{code, at}` only — code is a server error code (`rate_limited`, `quota_exhausted`, `provider_timeout_before_output`, …), `at` ISO-8601 UTC. No upstream bodies. |
| `routes[].cooling_seconds` | int | >0 while the local guard holds the route (currently Gemini). |
| `routes[].free` | bool | `true` for every route the server enables (paid models are rejected at config). |
| `routes[].billing` | string | e.g. `free_tier`, `promo_free_flash_paid_pro`, `upstream_free_tiers_via_self_hosted_router`. |
| `routes[].policy_url` | string | Provider privacy policy. OpenCode: `https://opencode.ai/legal/privacy-policy`. |
| `routes[].data_note` | string | Short machine tag for the privacy copy (`zero_retention`, `free_tier_may_train`, `zero_retention` (OpenCode default free models), …). |
| `primary_route` | string \| null | First route of `chain`, tried first in auto mode (default `gemini` since w6; `openrouter` when only the frozen single route exists). |
| `routes[].primary` | bool | `true` only for `primary_route`. Per-route `status` is availability, not "selected". |
| `chain` | string[] | Auto order. Default since w6: `gemini, openrouter, groq, opencode, agnes` (only routes with a key). |

Status is per Edge isolate (best effort, in memory); a fresh isolate reports `online` until it sees an error.

## 2. Selecting a route / model (request headers on chat turn requests)

| Header | Values | Behaviour |
|---|---|---|
| `X-Catpaw-Route` | `auto` (default) \| a route `id` | Chosen route is tried first; the rest of the chain stays as failover. |
| `X-Catpaw-Model` | a model `id` from that route's `models[]` | Only valid together with a concrete `X-Catpaw-Route`. Applied to that route only; failover routes use their default model. |
| `X-Catpaw-Route-Events` | `1` | Opt in to the SSE `model_route` event (§3). |

Validation runs on every catpaw-api request that carries the headers (not only chat), so send them only on chat calls or keep them valid.

**Invalid values are rejected, not silently ignored** (decision):

| Case | HTTP | `error.code` |
|---|---|---|
| Route id unknown | 422 | `model_route_unknown` |
| Route known but not configured on this server | 422 | `model_route_unavailable` |
| Model not in the route's allow-list, or model given with `auto` | 422 | `model_not_allowed` |

A route that is configured but `degraded`/`offline` is still accepted; if it fails before output the
turn fails over along the chain and the SSE `model_route` event reports it.

## 3. SSE: `model_route` event (once per provider round, before the first visible output)

```json
{ "type": "model_route",
  "data": { "route": "gemini", "model": "gemini-3.5-flash-lite",
            "requested_route": "openrouter", "failover": true,
            "from": ["openrouter"], "switches": [{ "from": "openrouter", "to": "gemini", "code": "rate_limited" }],
            "attempt": 2 } }
```

| Field | Notes |
|---|---|
| `route` / `model` | Route and model that actually produced this round. |
| `requested_route` | `X-Catpaw-Route` value, or `auto`. |
| `failover` | `true` if any earlier route failed in this round. |
| `from` | Route ids that failed before this one, in order. |
| `switches[]` | `{from, to, code}` hops; `code` is the failure code. |
| `attempt` | 1-based attempt number. |

**Opt-in:** only sent when the chat request carries `X-Catpaw-Route-Events: 1` (current iOS builds throw on
unknown event types, same pattern as `X-Catpaw-Reasoning-Summary`). At most one `model_route` per turn
(the first provider round); later rounds after tool/device results are not re-announced in v1. Client copy suggestion: when `failover` is true show “已切换到 {display_name}”.

## 4. `/readyz` additions

`model_routes`: `{schema_version, chain, auto_failover, routes:[{id, provider, model, configured, available, cooling_seconds?, billing}]}` — unauthenticated summary without errors/policy fields.

## 5. Consent

`config.routeHash` hashes the whole chain description (providers, models, policy URLs, data fields), so adding
OpenCode or changing models forces re-consent. With OpenCode configured the consented route also carries
`opencode_disclosure` (messages and history are sent to OpenCode Zen, with its policy links) and the data field
`prompt_and_history_sent_to_opencode_zen_free_models`; the consent screen must show that text and the policy URLs.

With a Gemini key configured (Gemini is the auto default first route, `data_note: free_tier_may_train`) the consented
route carries `gemini_disclosure` (`GEMINI_FREE_TIER_DISCLOSURE` in config.mjs: messages, history and memory context go to
the Google Gemini API free tier, which may retain them, use them for training and have humans review them; link
https://ai.google.dev/gemini-api/terms) and the data field `prompt_and_history_sent_to_google_gemini_free_tier`. The iOS
consent sheet shows it before the OpenCode text (`NativeChatHTTPBackend.consentBody`). Because the disclosure is part of
the hashed route, adding it or changing its wording changes `routeHash`, so every existing consent must be given again
(`provider_consent_required` until the user re-consents). The alternative is a paid / zero-retention Gemini setup, in which
case this disclosure should be revised in the same change.

## 6. Server configuration (env, no secrets returned)

| Env | Meaning |
|---|---|
| `CATPAW_OPENCODE_API_KEY` | OpenCode Console API key (Bearer). Route enabled only when set. See `opencode-route.md`. |
| `CATPAW_OPENCODE_BASE_URL` | Optional `https://…` base; default `https://opencode.ai/inference/openai/v1` (official docs). `/chat/completions` is appended. |
| `CATPAW_OPENCODE_MODEL` | Default model, default `deepseek-v4.1-flash-free`. Must end in `-free`. |
| `CATPAW_OPENCODE_MODELS` | `X-Catpaw-Model` allow-list for OpenCode; **replaces** the default `deepseek-v4.1-flash-free,glm-5.3-flash-free,longcat-2.5-preview-free,space-bunny-free` (zero-retention free models). Every entry must end in `-free`. |
| `CATPAW_<ROUTE>_MODELS` | Other routes: extra allowed models on top of the default, comma list, max 20. OpenRouter entries must end in `:free`. |
| `CATPAW_MODEL_ROUTE_ORDER` | Optional explicit order; default `gemini,openrouter,groq,opencode,agnes` (w6). `CATPAW_GEMINI_ROUTE` unset = `primary`; `fallback` restores the old `openrouter,gemini,…` order. |
