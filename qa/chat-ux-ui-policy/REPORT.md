# chat-ux #3 card-vs-text eval

- Ran: 2026-10-16T13:13:01.323Z (UTC) · route agnes · model `agnes-3.0-flash` · temperature 0 · 1 run(s) × 20 cases
- **Hit rate: 20/20 = 100.0%** (threshold 85%) · errors 0 · PASS
- Prompt sha256 `d3f51bb4283a4b4f…` = server `uiPrompt` (incl. UI_POLICY) + `GROUNDED_PROMPT`; tools = [render_ui] only.
- Limits: one provider route (Agnes; production chain also has OpenRouter/Gemini), tool list reduced to render_ui, no device tools; card *kind* is recorded but not scored.

## Misses

| run | case | expected | got | kind |
|---|---|---|---|---|
| – | – | – | – | – |
