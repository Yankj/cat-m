# chat-ux #3 card-type eval (v2)

- Ran: 2026-10-16T14:44:28.363Z (UTC) · route agnes · model `agnes-3.0-flash` · temperature 0 · 3 runs × 20 cases
- **Type hit rate: 51/60 = 85.0%** (threshold 85%) · per run 18/20, 17/20, 16/20 · errors 0 · PASS
- Card-vs-text only (old metric): 55/60
- Scoring: card case = render_ui with the expected kind; text case = no render_ui.
- Path: real chat service (createCloudRuntime, in-memory repo) with production gates on; system prompt sha256 `1f110cad0b481cd9…` is what the server built; tools offered (23): delegate_task, delegate_plan_v1, agent_status, create_task, update_task, list_tasks, render_ui, memory_save, memory_search, memory_update, memory_forget, calendar_list, calendar_create, reminder_create, mail_compose, sms_compose, phone_call, contacts_search, maps_open, shop_open, alarm_set, shortcut_run, places_search.
- Limits: one provider route (Agnes; production chain also has OpenRouter/Gemini); memory tools offered without a memory snapshot prompt; tool calls recorded, not executed; history cases inject fixture tool results; other tool calls get canned results (CANNED in run-eval.mjs) and the loop continues up to 4 steps.

## Misses

| run | case | expected | got | tools called |
|---|---|---|---|---|
| 1 | c02 | confirm | sheet | list_tasks, render_ui |
| 1 | c10 | confirm | sheet | render_ui |
| 2 | c01 | choices | text |  |
| 2 | c06 | list | text | memory_search |
| 2 | c07 | place | text |  |
| 3 | c01 | choices | sheet | render_ui |
| 3 | c02 | confirm | sheet | render_ui |
| 3 | c04 | sheet | text |  |
| 3 | c06 | list | text |  |

## Note on the prompt hash

After this run, one policy line got a 「例：」 prefix (`- 例：「取消明早的闹钟，执行前让我确认」`) so the unit test still counts
exactly 3 negative examples. The wording the model sees is otherwise identical. A rerun to refresh the hash was started
at 22:51 (UTC+8) but stopped: the Agnes route was hitting the chat deadline (52–157 s per call), so its numbers would not
have been comparable.
