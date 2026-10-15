-- R3 chat attachments: private bucket for one-turn image uploads.
-- Clients never touch storage.objects directly: catpaw-api (service role) issues a
-- signed upload URL for {subject_id}/{attachment_id}, reads the object once to
-- validate/consume it, then deletes it. No permissive client policy is created.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-attachments', 'chat-attachments', false, 5242880, array['image/png', 'image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Defense in depth: even if a permissive policy is added later, anon/authenticated
-- sessions can never list, read, write or delete objects in this bucket.
drop policy if exists "chat_attachments_no_client_access" on storage.objects;
create policy "chat_attachments_no_client_access"
  on storage.objects
  as restrictive
  for all
  to anon, authenticated
  using (bucket_id <> 'chat-attachments')
  with check (bucket_id <> 'chat-attachments');
