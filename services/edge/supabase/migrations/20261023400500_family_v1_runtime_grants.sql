-- NoBug B2: catpaw-api (dedicated login in catpaw_records, no BYPASSRLS) calls the family entrypoints, which were
-- granted to service_role only -> every family route 503 with the flag on. Least privilege: schema USAGE plus EXECUTE
-- on the SECURITY DEFINER entrypoints the API store (family/pg-store.mjs) calls. No table grants: all access goes
-- through the functions. Reminder dispatch (claim_due_reminders / fire_reminder / release_reminder) has no API caller
-- and stays service_role only. Re-runnable.
grant usage on schema family to catpaw_records;
grant execute on function
  family.apply_command(uuid, jsonb, text),
  family.get_receipt(uuid, uuid),
  family.my_households(uuid),
  family.projection(uuid, uuid, date),
  family.changes(uuid, uuid, bigint, integer),
  family.settings_for(uuid, uuid),
  family.reader(uuid, uuid),
  family.memories_for(uuid, uuid, timestamptz, uuid, text),
  family.resolve_refs(uuid, uuid, jsonb),
  family.memory_audit(uuid, uuid)
to catpaw_records;
