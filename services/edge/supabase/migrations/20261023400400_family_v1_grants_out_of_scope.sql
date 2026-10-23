-- v0.4 deploy review: shared read-only access (household grants) is out of scope for this release.
-- Remove the grant command types so family.apply_command cannot dispatch them even if the API guard regresses
-- (an unknown type is rejected as command_invalid). household_grants stays empty; family.reader() keeps its grantee
-- branch but no grant can be created. Reversible: re-insert ('grant.upsert','cmd_grant_upsert_counted'),
-- ('grant.revoke','cmd_grant_revoke_counted').
delete from family.command_types where type in ('grant.upsert', 'grant.revoke');
