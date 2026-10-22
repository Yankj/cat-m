-- Extra local-only Supabase surface so EVERY migration applies on a plain PG17 + pgvector (NOT for production).
create schema if not exists extensions;
create schema if not exists storage;
create table if not exists storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
do $$ begin if not exists (select 1 from pg_roles where rolname='catpaw_records') then create role catpaw_records nologin; end if; end $$;
create schema if not exists cron;
create table if not exists cron.job(jobid bigserial primary key, jobname text);
create or replace function cron.schedule(text, text, text) returns bigint language sql as 'select 1::bigint';
create or replace function cron.unschedule(bigint) returns boolean language sql as 'select true';
