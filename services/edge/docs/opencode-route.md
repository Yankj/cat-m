# OpenCode Zen route (`opencode`)

Direct OpenAI-compatible route to OpenCode Zen free models (no aggregator in between).
Source: https://opencode.ai/docs/zen/ (read 2026-10-16).

- Endpoint (official docs): `POST https://opencode.ai/inference/openai/v1/chat/completions`, `Authorization: Bearer <key>`.
  The community-used `https://opencode.ai/zen/v1/...` is not used; override only via `CATPAW_OPENCODE_BASE_URL`.
- Public model list (no key): `GET https://opencode.ai/inference/v1/models`.
- Default model `deepseek-v4.1-flash-free`; default `X-Catpaw-Model` allow-list:
  `deepseek-v4.1-flash-free`, `glm-5.3-flash-free`, `longcat-2.5-preview-free`, `space-bunny-free` —
  the free models the docs mark "zero-retention, not used for training" (all list tool calling on models.dev).
- Only `*-free` ids are accepted (`paid_or_router_model_denied` otherwise), so the key cannot run paid models.
  Free models are "free for a limited time"; when one is removed, the route fails over (before any output) and
  `CATPAW_OPENCODE_MODEL` / `CATPAW_OPENCODE_MODELS` should be updated.
- Do **not** add `big-pickle`, `ll-alpha-free`, `exo-free`, `mimo-*-free`, `nemotron-*-free`, `muse-spark-*-contributor-free`
  or `cat-jam-free`: their data may be used for training or retained (see the docs' Privacy section).
- Route list: `display_name` `OpenCode Zen (free)`, `data_note` `zero_retention`,
  `policy_url` `https://opencode.ai/legal/privacy-policy` (terms: `https://opencode.ai/legal/terms-of-service`).

## Consent

With the key set, the consented route adds `opencode_disclosure` and data field
`prompt_and_history_sent_to_opencode_zen_free_models`; `routeHash` changes, so users re-consent.

## Getting an OpenCode key (user-run)

1. Sign in at https://opencode.ai (Console). The docs ask you to add billing details/credits before issuing a key;
   free models cost $0, but set a **monthly limit** and disable auto-reload in the console to rule out charges.
2. Create an API key in the console and copy it.
3. Set Supabase secrets: `CATPAW_OPENCODE_API_KEY=<key>`; optionally `CATPAW_OPENCODE_MODEL`, `CATPAW_OPENCODE_MODELS`,
   `CATPAW_OPENCODE_BASE_URL`, `CATPAW_MODEL_ROUTE_ORDER` (default `openrouter,gemini,groq,opencode,agnes`).
