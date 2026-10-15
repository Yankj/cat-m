# catpaw.feature-enrollment.v1: turning features on with an invite code

This replaces hand-typing demo-account UUIDs into `CATPAW_FEATURE_ALLOWLIST_SUBJECTS`.

## Gate rule
- Each feature gate env (`CATPAW_AGENT_MEMORY_ENABLED`, `CATPAW_TASK_TOOLS_ENABLED`, `CATPAW_GENERATIVE_UI_ENABLED`, `CATPAW_DEVICE_TOOLS_ENABLED`, `CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED`, new `CATPAW_PROACTIVE_ENABLED`; plus `CATPAW_PROACTIVE_TOOLS_ENABLED` for creating the task store) means:
  - `true`/`1`: on for everyone.
  - `allowlist`, **or unset**: on for subjects in `CATPAW_FEATURE_ALLOWLIST_SUBJECTS` **or** with a row in `feature_access.enrollments` for that feature.
  - anything else (`false`, `off`, …): off for everyone, enrollments ignored.
- Behaviour change: unset used to mean off (and `CATPAW_TASK_TOOLS_ENABLED` unset used to mean on). With no env set and nobody enrolled, nobody gets anything, which matches production today.
- Feature keys: `agent_memory`, `task_tools`, `generative_ui`, `device_tools`, `proactive` (the catpaw-proactive function and the `proactive_suggestion` SSE).
- catpaw-api and catpaw-proactive keep a per-instance cache of the enrollments table. It is refreshed at most every 30 s on API requests. A successful enroll is visible right away on the instance that handled it, and on the others within 30 s.
- catpaw-proactive: every user endpoint answers `403 {code: feature_disabled}` unless the caller passes the `proactive` gate. Scheduler (secret) endpoints are not affected.

## API (catpaw-api)
All need `Authorization: Bearer <Supabase access token>`.

`POST /catpaw/features/v1/enroll`, body `{"invite_code": "CP-ABCD-EFGH-JK23"}`. Case, spaces, dashes and the `CP` prefix are ignored.
- `200 {contract, status: "ok" | "already_enrolled", enrolled: true, features: {agent_memory: bool, task_tools: bool, generative_ui: bool, device_tools: bool, proactive: bool}}`
- `422 {error:{code:"invite_invalid"}}`: unknown, expired, revoked or used-up code, or malformed input. These cases are deliberately indistinguishable.
- `429 {error:{code:"rate_limited", retry_after_sec}}` with a `Retry-After` header. Limits: 5 failed attempts per user per 15 min and 30 failed attempts per minute globally (both in the DB), plus 10 requests per user per minute per instance.
- `401 session_required`.

`GET /catpaw/features/v1/me` returns the same `{contract, enrolled, features}`. `features` reflects env gates plus enrollment, so the client can show or hide entry points.

## iOS (for 方块 / Grok Bot)
- Settings, then a "邀请码" row. Show it while `GET /me` returns `enrolled == false`; it opens a single text field ("输入邀请码") and a 提交 button.
- Submit: `POST /enroll`.
  - On 200: toast "已开启新功能", cache `features`, and reload the feature-dependent UI. The memory library, proactive suggestions and tools take effect on the next request (no re-login needed).
  - On 422: "邀请码无效或已过期".
  - On 429: "尝试次数过多，请 N 分钟后再试" (N from `retry_after_sec`); disable the button until then.
  - On 401: re-authenticate.
- Do not log or persist the code. Trim input. Uppercase as the user types.
- Call `GET /me` after login and on app foreground to decide what to show.

## Invite codes (operators)
- Only `sha256('catpaw-invite-v1:' || normalized)` is stored. Generate a code in the Supabase SQL editor:
  `select feature_access.create_invite();` (one use, all features, valid 30 days), or
  `select feature_access.create_invite(array['agent_memory','proactive'], 5, interval '7 days', 'demo iPad');`
- The plaintext is returned once in the result grid and is not recoverable. Send it to the user over a private channel.
- Revoke a code: `update feature_access.invite_codes set revoked_at = now() where note = '…';`
- Remove a user: `delete from feature_access.enrollments where subject_id = '…';`
- Simpler equivalent without a code: `insert into feature_access.enrollments(subject_id, feature) select id, f from auth.users, unnest(array['agent_memory','task_tools','generative_ui','device_tools','proactive']) f where email = 'demo@…' on conflict do nothing;`
