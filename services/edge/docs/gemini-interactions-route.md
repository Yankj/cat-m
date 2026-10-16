# Gemini route (Interactions API)

The Gemini route in the free route chain (`_shared/core/src/free-route-chain.mjs` and `gemini-interactions-route.mjs`) now uses Google's Interactions API, `POST /v1beta/interactions?alt=sse`, which the docs recommend for new projects. It runs stateless with `store=false`.

## Configuration (env only; never commit, never log)
| Variable | Values | Default |
| --- | --- | --- |
| `CATPAW_GEMINI_API_KEY` | AI Studio API key | unset = no Gemini route |
| `CATPAW_GEMINI_ROUTE` | `off` / `primary` / `fallback` | `fallback` once the key is set |
| `CATPAW_GEMINI_MODEL` | model id | `gemini-3.5-flash-lite` (use `gemini-3.8-flash` for better quality) |
| `CATPAW_GEMINI_RPM` | per-instance requests per minute | `10` |
| `CATPAW_GEMINI_PROTOCOL` | `interactions` / `openai_compat` | `interactions` |
| `CATPAW_GEMINI_{FIRST_EVENT,IDLE,TOTAL}_TIMEOUT_MS` | 1000–110000 | 20000 |

- `primary` puts Gemini first: `gemini, openrouter, groq, agnes`, keeping only routes that have a key.
- `fallback` puts it after OpenRouter.
- An explicit `CATPAW_MODEL_ROUTE_ORDER` always wins.
- Setting the key changes the consented route hash, so users see the model-consent sheet again. That is intended: the Gemini free tier is "used to improve our products".

## Behaviour
- **Streaming:** the adapter reads the `step.start`, `step.delta`, `step.stop` and `interaction.completed` events. Text deltas become `text_delta`. `thought_summary` deltas become `thinking_delta`, and are only requested when the client sends `X-Catpaw-Reasoning-Summary: 1`.
- **Tools:** our OpenAI-style tool definitions become `{type:'function', name, description, parameters}`.
  - Streamed `function_call` steps, with arguments accumulated from `arguments_delta`, become `tool_call` events. These feed the existing tool, device_call and approval chain unchanged, including `reminder_create`.
  - History is replayed as `user_input`, `model_output`, `function_call` and `function_result` steps.
- **Thought signatures:** Gemini 3 wants its own thought steps replayed with each function call. They are cached per call id in the isolate for 30 minutes.
  - If the cache misses (other isolate or restart) and Google answers 400, the chain fails over before any output. It never retries Gemini in a loop.
- **Images:** inline `data:image/...;base64` parts become `{type:'image', mime_type, data}`. Remote URLs are rejected, so there is no server-side fetch.
  - The live image route (`imageTransport`) is still the separately consented OpenRouter vision route. Pointing image turns at Gemini needs a vision-consent route change, which is not part of this PR.
- **Rate limits:**
  - Per-isolate sliding window at `CATPAW_GEMINI_RPM`.
  - On a 429 or `RESOURCE_EXHAUSTED`, the route cools down: Retry-After or RetryInfo if given, else 15 s, 30 s and so on up to 10 min. Per-day quota cools down for 1 h.
  - While over the limit or cooling down, the route answers `rate_limited` or `quota_exhausted` without calling Google, so the chain moves on to OpenRouter or Agnes in the same turn.

## provider_timeout fix (same PR)
- Previously, a route that streamed only hidden thinking (the client did not ask for reasoning summaries) and then stalled failed with `provider_timeout`. That code requires reconciliation, so the turn ended `outcome_unknown` instead of failing over.
- Hidden thinking no longer counts as output. Such a stall is now `provider_timeout_before_output` and fails over to the next route.
- Thinking that was actually shown to the client still counts as output.

## Not verified live
There was no Gemini key when this was written, so nothing has run against Google yet. Check these against the live API:
- Exact error payloads (RetryInfo, the per-day quota message).
- The `thinking_summaries` field name in `generation_config`.
- Field names of the `thought_signature` delta (the adapter copies the whole delta).
- Whether a missing signature is really rejected.
- Chinese quality and latency.
