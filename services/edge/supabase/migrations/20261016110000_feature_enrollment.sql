-- catpaw.feature-enrollment.v1 + missing catpaw_records grants. WRITTEN ONLY — NOT APPLIED (apply needs the user's approval).
-- Feature switches live in the DB instead of function env: a row in feature_access.enrollments counts as being on
-- CATPAW_FEATURE_ALLOWLIST_SUBJECTS for that feature (the env allowlist keeps working). Invite codes are stored only
-- as SHA-256 hashes; plaintext is produced once by feature_access.create_invite() and never stored or logged.
create extension if not exists pgcrypto with schema extensions;
create schema if not exists feature_access;
revoke all on schema feature_access from public, anon, authenticated;

create table feature_access.invite_codes (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  features text[] not null check (cardinality(features) > 0 and features <@ array['agent_memory','task_tools','generative_ui','device_tools','proactive']),
  max_uses integer not null default 1 check (max_uses between 1 and 10000),
  uses integer not null default 0 check (uses >= 0),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  note text check (char_length(note) <= 200),
  created_at timestamptz not null default now()
);
create table feature_access.enrollments (
  subject_id uuid not null references auth.users(id) on delete cascade,
  feature text not null check (feature in ('agent_memory','task_tools','generative_ui','device_tools','proactive')),
  invite_id uuid references feature_access.invite_codes(id) on delete set null,
  enrolled_at timestamptz not null default now(),
  primary key (subject_id, feature)
);
create table feature_access.enroll_attempts (
  id bigint generated always as identity primary key,
  subject_id uuid not null,
  ok boolean not null,
  at timestamptz not null default now()
);
create index enroll_attempts_subject_at on feature_access.enroll_attempts (subject_id, at desc);
create index enroll_attempts_at on feature_access.enroll_attempts (at desc);
alter table feature_access.invite_codes enable row level security;
alter table feature_access.enrollments enable row level security;
alter table feature_access.enroll_attempts enable row level security;

-- Must match hashInviteCode() in _shared/enrollment/contract.mjs (input is the normalized 12-char code).
create function feature_access.invite_code_hash(normalized text) returns text language sql immutable
  set search_path = '' as $$ select encode(extensions.digest('catpaw-invite-v1:' || normalized, 'sha256'), 'hex') $$;

-- Operator-only (SQL editor / service_role). Returns the plaintext code ONCE; only its hash is stored.
create function feature_access.create_invite(
  p_features text[] default array['agent_memory','task_tools','generative_ui','device_tools','proactive'],
  p_max_uses integer default 1, p_ttl interval default interval '30 days', p_note text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(12); raw text := ''; i int;
begin
  for i in 0..11 loop raw := raw || substr(alphabet, 1 + (get_byte(b, i) % 31), 1); end loop;
  insert into feature_access.invite_codes(code_hash, features, max_uses, expires_at, note)
    values (feature_access.invite_code_hash(raw), p_features, p_max_uses, now() + p_ttl, p_note);
  return 'CP-' || substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4);
end $$;

-- Called by catpaw-api. Rate limit: 5 failed attempts per subject per 15 min, 30 failed attempts per minute globally.
create function feature_access.redeem_invite(p_subject uuid, p_hash text)
returns table(status text, features text[]) language plpgsql volatile security definer set search_path = '' as $$
declare inv feature_access.invite_codes%rowtype; have text[];
begin
  if (select count(*) from feature_access.enroll_attempts a where a.subject_id = p_subject and not a.ok and a.at > now() - interval '15 minutes') >= 5
     or (select count(*) from feature_access.enroll_attempts a where not a.ok and a.at > now() - interval '1 minute') >= 30 then
    return query select 'rate_limited'::text, array[]::text[]; return;
  end if;
  select * into inv from feature_access.invite_codes c where c.code_hash = p_hash and c.revoked_at is null and c.expires_at > now() for update;
  select coalesce(array_agg(e.feature), array[]::text[]) into have from feature_access.enrollments e where e.subject_id = p_subject;
  if inv.id is null then
    insert into feature_access.enroll_attempts(subject_id, ok) values (p_subject, false);
    return query select 'invalid'::text, array[]::text[]; return;
  end if;
  if inv.features <@ have then
    insert into feature_access.enroll_attempts(subject_id, ok) values (p_subject, true);
    return query select 'already_enrolled'::text, inv.features; return;
  end if;
  if inv.uses >= inv.max_uses then
    insert into feature_access.enroll_attempts(subject_id, ok) values (p_subject, false);
    return query select 'invalid'::text, array[]::text[]; return;
  end if;
  update feature_access.invite_codes set uses = uses + 1 where id = inv.id;
  insert into feature_access.enrollments(subject_id, feature, invite_id) select p_subject, f, inv.id from unnest(inv.features) f on conflict do nothing;
  insert into feature_access.enroll_attempts(subject_id, ok) values (p_subject, true);
  delete from feature_access.enroll_attempts a where a.at < now() - interval '1 day';
  return query select 'ok'::text, inv.features;
end $$;

revoke all on all functions in schema feature_access from public, anon, authenticated;
grant usage on schema feature_access to catpaw_records, service_role;
grant select on feature_access.enrollments to catpaw_records, service_role;
grant execute on function feature_access.redeem_invite(uuid, text) to catpaw_records, service_role;
grant all on all tables in schema feature_access to service_role;
grant execute on function feature_access.create_invite(text[], integer, interval, text) to service_role;

drop policy if exists enrollments_catpaw_api on feature_access.enrollments;
create policy enrollments_catpaw_api on feature_access.enrollments for select to catpaw_records using (true);

-- Previously missing: catpaw-api connects as catpaw_records (no BYPASSRLS) and serves catpaw.agent-memory.v1 in-process.
-- pg-store.mjs filters every query by user_id = authenticated subject; these policies are the second layer.
grant usage on schema agent_memory to catpaw_records;
grant select, insert, update, delete on agent_memory.memories, agent_memory.memory_settings, agent_memory.journal_fragments to catpaw_records;
grant select on agent_memory.memory_tombstones to catpaw_records;
drop policy if exists memories_catpaw_api on agent_memory.memories;
create policy memories_catpaw_api on agent_memory.memories for all to catpaw_records using (true) with check (true);
drop policy if exists settings_catpaw_api on agent_memory.memory_settings;
create policy settings_catpaw_api on agent_memory.memory_settings for all to catpaw_records using (true) with check (true);
drop policy if exists fragments_catpaw_api on agent_memory.journal_fragments;
create policy fragments_catpaw_api on agent_memory.journal_fragments for all to catpaw_records using (true) with check (true);
drop policy if exists tombstones_catpaw_api on agent_memory.memory_tombstones;
create policy tombstones_catpaw_api on agent_memory.memory_tombstones for select to catpaw_records using (true);
