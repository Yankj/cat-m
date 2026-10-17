-- 20261017050000: a feedback row written under the old check (legacy 'disturbing') must survive the constraint swap.
insert into auth.users(id) values ('00000000-0000-4000-8000-0000000000f1') on conflict do nothing;
insert into proactive.events(id, user_id, kind, title, body, payload, dedupe_key, push_state)
values ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000f1', 'proactive_decision', 'legacy feedback', 'b',
        '{"decision":"card","delivery":"device"}', 'feedback-seed-disturbing', 'skipped');
insert into proactive.feedback(event_id, user_id, kind) values ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000f1', 'disturbing');
