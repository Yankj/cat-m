# Daily model call limit (`model_daily_limit`)

Optional server-side quota in `catpaw-api`, **off by default** (`_shared/api.mjs`, provider admission). Not a provider quota.

- Counted per `subject_id` per **UTC** date (resets 08:00 Asia/Shanghai). Every provider request counts,
  including the continuation after a device result / approval, so one confirmed tool flow costs ≥ 2.
- Counter row: `public.records` owner=`system:provider-budget`, kind=`daily-model-calls`,
  id=`<subject_id>:<YYYY-MM-DD UTC>`, data=`{"id": ..., "count": n}`.
- Only when the limit is enabled: when `count >= limit` the turn fails with HTTP 429 `model_daily_limit`.
- All routes (OpenRouter, Gemini, Groq, Agnes) share this one counter: it is taken before route selection.

| Env | Default | Notes |
|---|---|---|
| `CATPAW_DAILY_CALL_LIMIT` | unset = unlimited | Only a positive integer enables the limit. Unset/empty/invalid → no limit and no counter is read or written (previously hard-coded 20). |
| `CATPAW_DAILY_MODEL_CALL_EXEMPT_SUBJECTS` | empty | Comma-separated subject UUIDs that bypass the limit (not counted). |

Reset one subject for today (write; needs approval):

```sql
update public.records set data = jsonb_set(data,'{count}','0'::jsonb), updated_at = now()
where owner='system:provider-budget' and kind='daily-model-calls'
  and id = '<subject_id>:' || to_char(now() at time zone 'UTC','YYYY-MM-DD');
```

Gemini's own per-instance RPM guard (`CATPAW_GEMINI_RPM`) is separate and unaffected.
