# catpaw.agent-memory.v1 — Wave 2 B1 (agent memory + recall)

Status: code + tests on `feat/agent-memory-recall`. **Gate off by default. Migration written, NOT applied.**

## Gate

| secret | values | default |
|---|---|---|
| `CATPAW_AGENT_MEMORY_ENABLED` | `true` · `allowlist` (uses `CATPAW_FEATURE_ALLOWLIST_SUBJECTS`) · unset/off | off |
| `CATPAW_SCHEDULER_SECRET` | journal cron shared secret (already used by catpaw-proactive) | — |

Off ⇒ no store is created, no tools are offered, no recall, `/catpaw/agent-memory/v1/*` → 404.
Turning the gate on before migration `20261016090000_agent_memory.sql` is applied would fail every turn of an
allowlisted user, so the order is: apply migration → gate `allowlist` → `true`.

## Privacy

- **Consent first.** Settings default to `use_memory=false, auto_save=false, consented_at=null`. Turning either on
  requires `consent:true` in the same or an earlier PATCH (DB check constraint mirrors this). `consent:false` turns both off.
- **Isolation.** Every store query filters by `user_id`; the migration adds RLS `user_id = auth.uid()` as a second layer.
  Tests cover list/search/get/patch/delete/undo/forget/recall across two users.
- **Delete.** Item delete, undo, "forget" and "clear all" are hard deletes (journal fragments included in clear all).
- **Temporary conversation.** The client sends `X-Catpaw-Memory-Mode: ephemeral` on every turn of a temporary chat:
  no recall, no memory tools, no journal fragment. Nothing is written.
- Recalled memory is injected as *untrusted data* and is never projected in `GET …/turns/{t}`.

## Agent tools (gated registry, need `X-Catpaw-Approval-Contract`)

| tool | approval | notes |
|---|---|---|
| `memory_save{kind,content,expires_at?}` | never | offered only when `auto_save` is on; emits `memory_saved` |
| `memory_search{query,k?}` | never | read-only |
| `memory_update{id,content}` | never | reversible in Settings |
| `memory_forget{ids[]｜query}` | **always** (approval.v1 card) | card summary lists the matching contents |

## Recall (per turn, frozen at admission)

profile + pinned entries (pinned first, ≤ 1,500 tokens) + top-k=6 others ranked by relevance × (0.5 + 0.5·decay),
half-life 30 days. Relevance = cosine of embeddings when an `embed` provider is configured, otherwise lexical overlap
(words + CJK bigrams). **No embeddings provider is wired yet** (needs a key/cost decision), so production would use the
lexical fallback. Edits and deletes apply from the next turn. Expired entries are skipped.

## Events (SSE, inside the usual native-chat envelope with `conversation_id`, `turn_id`, `sequence`)

```jsonc
{"type":"memory_recalled","data":{"ids":["uuid", "..."]}}            // right after turn_started, only if ids non-empty
{"type":"memory_saved","data":{"memory":{"id","kind","content"},"undo_token":"opaque","call_id":"..."}}  // right after its tool_result
```

## REST (`/functions/v1/catpaw-api/catpaw/agent-memory/v1`, Supabase JWT)

| method | path | body / result |
|---|---|---|
| GET | `/settings` | `{settings:{use_memory,auto_save,consented_at}}` |
| PATCH | `/settings` | `{consent?,use_memory?,auto_save?}` (booleans) → 409 `memory_consent_required` |
| GET | `/items?q=&kind=` | `{memories:[{id,kind,content,pinned,expires_at,source_conversation_id,created_at,updated_at}]}` |
| POST | `/items` | `{kind,content,pinned?,expires_at?}` → 201 |
| PATCH | `/items/{id}` | `{content?,pinned?}` |
| DELETE | `/items/{id}` | `{deleted:1}` |
| POST | `/undo` | `{undo_token}` → `{deleted:1,id}`; 410 `undo_unavailable` after 24 h or reuse |
| POST | `/clear` | `{confirm:"delete_all"}` (client shows the second confirmation first) |
| POST | `/journal/tick` | cron only, header `x-catpaw-scheduler-secret`; `{day?}` → `{day,written}` |

## Journal

Each non-ephemeral turn of a consenting user with `auto_save` stores its message (≤ 400 chars) as a fragment. The daily
tick (00:10 Asia/Shanghai, pg_cron + pg_net, commented in the migration) compresses yesterday's fragments into one
`journal` memory (90-day expiry) and deletes the fragments. Without a summarizer it writes a deterministic digest.

## Relation to catpaw.memory.v1

`core/src/memory-*.mjs` already implements a source-backed memory (claims with sources, generations,
`propose_memory_v1` + user confirmation, conflicts). Plan §1 describes a simpler content model, which is what this
module implements, in its own schema. Two memory systems must not both be live for one user: before the gate goes to
`true`, decide whether agent-memory replaces catpaw.memory.v1 or is folded into it (owner decision).
