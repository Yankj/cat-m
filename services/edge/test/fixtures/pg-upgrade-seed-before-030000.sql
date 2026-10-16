-- Codex PR90g #5: a row left in 'sending' by the 20261017020000 code (claimed, crashed; no claim/lease columns yet).
insert into proactive.events(user_id, kind, title, body, payload, dedupe_key, push_state)
values ('00000000-0000-4000-8000-0000000000a1', 'proactive_decision', 'legacy sending', 'b', '{"decision":"notify","delivery":"remote","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'upgrade-seed-sending', 'sending');
