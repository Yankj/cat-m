# Feature gates for demo / staging (A1 approval, A2 task tools, catpaw.ui.v1)

## What exists (read-only check, 2026-10-15 23:5x CST)

- `list_branches` (project `<your-project-ref>`, catpaw-m, us-east-1): **no branches**.
- Organization plan: **free**. Supabase branching requires a paid (Pro) plan, so a branch is not possible today
  without upgrading the organization.
- `get_cost(branch)`: **$0.01344 per hour** (≈ $9.8 per month if left running), on top of the Pro plan.
- A branch is a separate database (migrations replayed, no production data or auth users, separate secrets and
  function deploys).

## Recommendation: per-user allowlist on the production deploy (no branch)

Server env (Edge Function secrets of catpaw-api):

Default (user decision 2026-10-17 08:51): **every gate is on for everyone when unset**; a blocklist turns specific users off.

| secret | values | default (unset/empty) |
|---|---|---|
| `CATPAW_TASK_TOOLS_ENABLED` | `true` · `allowlist` · `false`/`off` | on |
| `CATPAW_GENERATIVE_UI_ENABLED` | `true` · `allowlist` · `false`/`off` | on |
| `CATPAW_AGENT_MEMORY_ENABLED` | `true` · `allowlist` · `false`/`off` (needs the agent_memory migrations) | on |
| `CATPAW_DEVICE_TOOLS_ENABLED` | `true` · `allowlist` · `false`/`off` (catpaw.device.v1; no migration) | on |
| `CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED` | `true` · `allowlist` · `false`/`off` (chat `proactive_suggestion` SSE; needs `20261016030000`, `20261016040000`) | on |
| `CATPAW_PROACTIVE_ENABLED` | `true` · `allowlist` · `false`/`off` (catpaw-proactive) | on |
| `CATPAW_PROACTIVE_TOOLS_ENABLED` | anything but `false`/`off` creates the proactive store (bootstrap.ts) | on |
| `CATPAW_FEATURE_ALLOWLIST_SUBJECTS` | comma-separated auth user UUIDs; only used by gates set to `allowlist` | empty |
| `CATPAW_FEATURE_BLOCKLIST_SUBJECTS` | comma-separated auth user UUIDs: **off for every feature**, even when the gate is on, allowlisted or enrolled; invalid entries are ignored | empty |

Parsing: trimmed, lower-cased; `true`/`1` → on, `allowlist` → allowlist, empty/unset → on, anything else (`false`, `off`, `yes`, typos) → off.
Per-feature blocking is not supported (enrollment rows only grant); use the gate value or the global blocklist.

- `allowlist` offers the tool only when `turn.subject_id` is in the allowlist or enrolled.
- A1 (approval.v1) is a negotiated contract that changes nothing by itself: it only matters when a gated tool is
  offered, so gating the tools (A2, render_ui) gates A1 in practice.
- The client still opts in with headers, so old builds are unaffected even for allowlisted users.
- Rollout: deploy with UI `allowlist` + task tools `allowlist` → test with demo accounts → flip to `true`.
- Rollback: unset or change the secret. Secrets apply to new function instances; a redeploy forces it immediately.

Why not a Supabase branch: separate database and auth users (demo accounts must be recreated), every migration and
secret duplicated, extra cost per hour, and the iOS DeviceTrial build would need a second backend origin.
Worth it only for schema changes that must not touch production (e.g. the unapplied proactive migrations).

## Steps that need the user's approval

1. Production deploy of catpaw-api containing the gate code (this branch).
2. Setting the three secrets (and the allowlist UUIDs).
3. Applying migrations `20261015120000`, `20261015120100`, `20261015150000` (A2 proactive store) to production —
   or creating a branch to apply them there first (branch has an hourly cost; confirm with `confirm_cost`).
4. Flipping any gate from `allowlist` to `true`.

## DB enrollment (catpaw.feature-enrollment.v1)
A row in `feature_access.enrollments` counts as allowlist membership for gates set to `allowlist` (unset gates are on for everyone). See [feature-enrollment.md](feature-enrollment.md).
