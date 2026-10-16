-- Codex PR90g #5: rows written by the code before 20261017020000 (no 'sending' state, no generation columns).
insert into auth.users(id) values ('00000000-0000-4000-8000-0000000000a1') on conflict do nothing;
insert into proactive.events(user_id, kind, title, body, payload, dedupe_key, push_state)
values ('00000000-0000-4000-8000-0000000000a1', 'proactive_decision', 'legacy pending', 'b', '{"decision":"notify","delivery":"remote","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'upgrade-seed-pending', 'pending'),
       ('00000000-0000-4000-8000-0000000000a1', 'proactive_decision', 'legacy sent', 'b', '{"decision":"notify","delivery":"remote","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'upgrade-seed-sent', 'sent');
