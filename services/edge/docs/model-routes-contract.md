# Model routes contract (`catpaw.model-routes.v1`)

Client-facing route list, route/model selection and per-turn route reporting. No secrets, no internal
base URLs (e.g. the self-hosted FreeLLMAPI address) are ever returned.

## 1. `GET /catpaw/model-routes/v1` (auth required, same Supabase JWT as chat)

```json
{
  "contract": "catpaw.model-routes.v1",
  "default_route": "auto",
  "chain": ["openrouter", "gemini", "freellmapi", "agnes"],
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
| `routes[].id` | string | `openrouter` \| `gemini` \| `groq` \| `freellmapi` \| `agnes`. Only routes whose key is configured are listed. |
| `routes[].display_name` | string | Human label (e.g. `Self-hosted FreeLLMAPI`). |
| `routes[].models[]` | `{id, default}` | Allow-list accepted in `X-Catpaw-Model`. Default model first. |
| `routes[].status` | enum | `online` (configured, no recent error), `degraded` (last error newer than last success, within 5 min), `offline` (cooling down after 429/quota, or last 3 attempts failed). |
| `routes[].last_error` | object\|null | `{code, at}` only — code is a server error code (`rate_limited`, `quota_exhausted`, `provider_timeout_before_output`, …), `at` ISO-8601 UTC. No upstream bodies. |
| `routes[].cooling_seconds` | int | >0 while the local guard holds the route (currently Gemini). |
| `routes[].free` | bool | `true` for every route the server enables (paid models are rejected at config). |
| `routes[].billing` | string | e.g. `free_tier`, `promo_free_flash_paid_pro`, `upstream_free_tiers_via_self_hosted_router`. |
| `routes[].policy_url` | string | Provider privacy policy. FreeLLMAPI: aggregator docs; upstream policies apply. |
| `routes[].data_note` | string | Short machine tag for the privacy copy (`zero_retention`, `free_tier_may_train`, `aggregator_forwards_upstream`, …). |
| `chain` | string[] | Auto order. |

Status is per Edge isolate (best effort, in memory); a fresh isolate reports `online` until it sees an error.

## 2. Selecting a route / model (request headers on chat turn requests)

| Header | Values | Behaviour |
|---|---|---|
| `X-Catpaw-Route` | `auto` (default) \| a route `id` | Chosen route is tried first; the rest of the chain stays as failover. |
| `X-Catpaw-Model` | a model `id` from that route's `models[]` | Only valid together with a concrete `X-Catpaw-Route`. |

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

Emitted by every chain deployment (the event type is ignored by clients that don't know it). A
continuation after a tool/device result is a new round and may emit another `model_route`.
Client copy suggestion: when `failover` is true show “已切换到 {display_name}”.

## 4. `/readyz` additions

`model_routes`: `{schema_version, chain, auto_failover, routes:[{id, provider, model, configured, available, cooling_seconds?, billing}]}` — unauthenticated summary without errors/policy fields.

## 5. Consent

`config.routeHash` hashes the whole chain description (providers, models, policy URLs, data fields), so adding
FreeLLMAPI or changing models forces re-consent. With FreeLLMAPI configured the consented route also carries
`aggregator_disclosure` and the data field `prompt_and_history_forwarded_via_self_hosted_freellmapi_to_upstream_free_providers`;
the consent screen must show that text and the policy URLs.
