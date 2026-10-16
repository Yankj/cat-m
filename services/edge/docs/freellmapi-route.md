# Self-hosted FreeLLMAPI route (`freellmapi`)

FreeLLMAPI (https://github.com/tashfeenahmed/freellmapi, MIT) is a self-hosted OpenAI-compatible router over many
free tiers. Upstream labels it *personal experimentation only*; Catpaw uses it as an optional aggregated fallback
for a personal app. OpenCode Zen free models are **not** a separate Catpaw route: add them inside FreeLLMAPI
(built-in "OpenCode Zen" provider or a custom OpenAI-compatible provider pointing at
`https://opencode.ai/zen/v1/chat/completions` with your OpenCode key).

## Behaviour
- `POST {BASE}/v1/chat/completions`, `Authorization: Bearer <unified key>`, `stream: true`, OpenAI tools.
- Same chain rules as other routes: failover only before visible output; `rate_limited` / 5xx / timeout-before-output
  move on to the next route; nothing is resent after output.
- Model defaults to `auto` (FreeLLMAPI follows its own fallback chain; it also fails over internally).
- The upstream that actually answered is in FreeLLMAPI's `x-routed-via` response header (not yet surfaced).

## Privacy / consent
Enabling the route changes `routeHash` (re-consent). The consented route gains
`aggregator_disclosure` and data field `prompt_and_history_forwarded_via_self_hosted_freellmapi_to_upstream_free_providers`.
Consent copy must say: messages go through your FreeLLMAPI server and are forwarded to the upstream free providers
you enabled there; each upstream's retention/training policy applies (some free tiers, e.g. Gemini free tier and some
OpenCode "free for feedback" models, may use data for training; OpenCode's DeepSeek V4.1 Flash Free / GLM-5.3-Flash Free /
LongCat 2.5 Preview Free are documented zero-retention).

## Deploy FreeLLMAPI (user-run)
1. On a server you control (VPS / home box with Docker):
   ```bash
   git clone https://github.com/tashfeenahmed/freellmapi.git && cd freellmapi
   printf "ENCRYPTION_KEY=%s\nPORT=3001\n" "$(openssl rand -hex 32)" > .env
   docker compose up -d            # binds 127.0.0.1:3001 by default
   ```
   (or the installer `curl -fsSL https://freellmapi.co/install.sh | bash` after reading it).
2. Open the dashboard (SSH tunnel to `localhost:3001`), add provider keys on **Keys** (e.g. OpenCode Zen, Google AI Studio,
   Groq, Cerebras…), order the **Fallback Chain**, copy the **unified API key**.
3. Expose it to Supabase Edge over **HTTPS** only (Edge cannot reach localhost): e.g. Caddy/nginx with TLS, or a
   Cloudflare Tunnel, in front of `127.0.0.1:3001`. Keep the unified key secret; FreeLLMAPI is single-user.
4. Smoke from your machine: `curl https://<host>/v1/chat/completions -H "Authorization: Bearer <key>" -H 'content-type: application/json' -d '{"model":"auto","messages":[{"role":"user","content":"你好"}],"stream":true}'`.
5. Set Supabase secrets: `CATPAW_FREELLMAPI_BASE_URL=https://<host>`, `CATPAW_FREELLMAPI_API_KEY=<unified key>`,
   optionally `CATPAW_FREELLMAPI_MODEL`, `CATPAW_FREELLMAPI_MODELS`, `CATPAW_MODEL_ROUTE_ORDER`.

## Risks
Free models rotate or disappear weekly; tool-calling quality varies by upstream (FreeLLMAPI rescues plain-text tool
calls but the device-tool chain should be smoke-tested per model); streaming depends on upstream; Chinese quality varies
(DeepSeek / GLM / Qwen / LongCat are strongest). Availability of the user's server becomes part of the chat path,
which is why it sits after OpenRouter/Gemini/Groq by default.
