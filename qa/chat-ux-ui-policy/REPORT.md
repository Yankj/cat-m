# chat-ux #3 card-type eval (v2)

- Ran: 2026-10-16T15:51:12.410Z (UTC) · route agnes · model `agnes-3.0-flash` · temperature 0 · 3 runs × 20 cases
- **Type hit rate: 57/60 = 95.0%** (bar: total ≥ 85% and each run ≥ 80%) · per run 17/20, 20/20, 20/20 · errors 0 · PASS
- Card-vs-text only (old metric): 60/60
- Scoring: card case = render_ui with the expected kind; text case = no render_ui.
- Path: real chat service (createCloudRuntime, in-memory repo) with production gates on; system prompt sha256 `f427ec54562e193e…` is what the server built; tools offered (23): delegate_task, delegate_plan_v1, agent_status, create_task, update_task, list_tasks, render_ui, memory_save, memory_search, memory_update, memory_forget, calendar_list, calendar_create, reminder_create, mail_compose, sms_compose, phone_call, contacts_search, maps_open, shop_open, alarm_set, shortcut_run, places_search.
- Limits: one provider route (Agnes; production chain also has OpenRouter/Gemini); memory tools offered without a memory snapshot prompt; tool calls recorded, not executed; history cases inject fixture tool results; other tool calls get canned results (CANNED in run-eval.mjs) and the loop continues up to 4 steps.

## Misses

| run | case | expected | got | tools called |
|---|---|---|---|---|
| 1 | c01 | choices | sheet | render_ui |
| 1 | c06 | list | sheet | render_ui |
| 1 | c10 | confirm | sheet | render_ui |
