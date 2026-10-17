-- 三角 deploy question 3: rows as production catpaw-proactive v6 writes them (no payload.delivery at all), plus the
-- explicit shapes, seeded right before 20261017010000.
insert into auth.users(id) values ('00000000-0000-4000-8000-0000000000b6') on conflict do nothing;
insert into proactive.events(user_id, kind, title, body, payload, dedupe_key, push_state)
values ('00000000-0000-4000-8000-0000000000b6', 'proactive_decision', 'v6 pending', 'b', '{"decision":"notify","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'v6-seed-pending-null', 'pending'),
       ('00000000-0000-4000-8000-0000000000b6', 'proactive_decision', 'v6 sent', 'b', '{"decision":"notify","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'v6-seed-sent-null', 'sent'),
       ('00000000-0000-4000-8000-0000000000b6', 'proactive_decision', 'device pending', 'b', '{"decision":"notify","delivery":"device","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'v6-seed-pending-device', 'pending'),
       ('00000000-0000-4000-8000-0000000000b6', 'proactive_decision', 'remote pending', 'b', '{"decision":"notify","delivery":"remote","suggestion":{"status":"pending","taken":[],"history":[],"ops":{}}}', 'v6-seed-pending-remote', 'pending'),
       ('00000000-0000-4000-8000-0000000000b6', 'agent_message', 'task push', 'b', '{}', 'v6-seed-agent', 'pending');
