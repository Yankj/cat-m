# Chat attachments — client contract (catpaw.chat-attachments.v1)

Images are uploaded **when selected** (with progress) and referenced by id when the message is sent.
Base: `/functions/v1/catpaw-api/catpaw/chat/v1/scopes/{scope_id}`. Headers as for all chat routes:
`Authorization: Bearer <session JWT>`, `apikey: <publishable key>`.

Availability: `GET /readyz` → `chat_capabilities.attachments`
`{contract, available, upload:"signed_put", max_count:1, max_bytes:5242880, mime_types:["image/png","image/jpeg"]}`.
Images also need `chat_capabilities.image_input == true` and an image consent for the conversation
(`/catpaw/privacy/v1/image-model-route`, `…/conversations/{c}/image-model-consent`, unchanged from v22).

## 1. Create — `POST /attachments`

```json
{"attachment_id":"<client UUID>","mime_type":"image/png","size_bytes":12345,"sha256":"<64 hex of the exact bytes>"}
```

→ `201 {"attachment":{id,state:"pending",mime_type,size_bytes,sha256,expires_at},
        "upload":{"method":"PUT","url":"https://…/storage/v1/object/upload/sign/chat-attachments/…?token=…",
                  "headers":{"Content-Type":"image/png","x-upsert":"false"},"expires_at":"…"}}`

- Idempotent on `attachment_id`: resending the same body returns the same attachment and a fresh upload URL
  while `pending`; `upload` is `null` once it is `ready`/`rejected`/`consumed`.
- Same id with different mime/size/sha → `409 attachment_conflict`.
- `422 image_mime_unsupported` (only PNG/JPEG), `413 image_too_large` (> 5 MiB), `422 image_hash_invalid`.
- Strip metadata before upload: PNG 8-bit RGB/RGBA with no ancillary chunks, baseline/progressive JPEG with a
  plain JFIF APP0 and no EXIF/APPn/COM; max 2048 px per side (same rules as v22 inline images).

## 2. Upload — `PUT <upload.url>`

Send the raw bytes with exactly `upload.headers` (no `Authorization` needed; the URL is the credential,
valid 2 h). Use a background `URLSession` upload task for progress. Never log the URL.

## 3. Complete — `POST /attachments/{id}/complete` (empty body or `{}`)

→ `200 {"attachment":{id,state:"ready",width,height,…}}` or `{"attachment":{state:"rejected",reason:"image_hash_mismatch"|…}}`.
- `409 attachment_upload_missing`: the PUT has not landed yet → retry after the upload finishes.
- `410 attachment_expired`: pending > 2 h → create a new attachment id.
- Idempotent; a rejected upload is deleted server-side (create a new id to retry).
- `GET /attachments/{id}` returns the same projection at any time.

## 4. Send — `POST /conversations/{c}/turns`

```json
{"schema_version":2,"turn_id":"…","expected_revision":n,"expected_grant_epoch":n,
 "message":{"id":"…","text":"caption (required)","attachment_ids":["<ready attachment id>"]},"context":[]}
```

- `409 attachment_not_ready` (pending/rejected), `409 attachment_consumed` (already used by another turn),
  `410 attachment_expired` (ready > 24 h), `404 attachment_not_found`.
- When the turn is accepted the object is deleted and the attachment becomes `consumed`; image bytes are
  used for this turn only (no image history, no re-use). Resending the **same** `turn_id` returns the
  replay (`{turn, replayed:true}`), never a second model call.
- Image turns run without tools; the SSE events are unchanged (see turn-cancel-contract.md for cancel).

## Legacy

The v22 inline form `message.attachments:[{id,mime_type,sha256,base64}]` (schema_version 2) is still
accepted. `attachments` and `attachment_ids` are mutually exclusive.

## Server side (reference)

Private bucket `chat-attachments` (5 MiB, PNG/JPEG), path `{subject_id}/{attachment_id}`; a restrictive
policy denies all anon/authenticated access, only catpaw-api (service role) reads/deletes. Attachment state
is kept in the existing record store (kind `chat-attachments`); stale pending/ready uploads are expired and
deleted lazily on the owner's next create.
