# Feature gates for demo / staging (A1 approval, A2 task tools, catpaw.ui.v1)

## What exists (read-only check, 2026-10-15 23:5x CST)

- `list_branches` (project `dbyklgxdvjbutxzsjeth`, catpaw-m, us-east-1): **no branches**.
- Organization plan: **free**. Supabase branching requires a paid (Pro) plan, so a branch is not possible today
  without upgrading the organization.
- `get_cost(branch)`: **$0.01344 per hour** (≈ $9.8 per month if left running), on top of the Pro plan.
- A branch is a separate database (migrations replayed, no production data or auth users, separate secrets and
  function deploys).

## Recommendation: per-user allowlist on the production deploy (no branch)

Server env (Edge Function secrets of catpaw-api):

| secret | values | default |
|---|---|---|
| `CATPAW_GENERATIVE_UI_ENABLED` | `true` · `allowlist` · unset/off | off |
| `CATPAW_TASK_TOOLS_ENABLED` | `true` · `allowlist` · `off` | `true` (current behaviour) |
| `CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED` | `true` · `allowlist` · unset/off (chat `proactive_suggestion` SSE; needs migrations `20261016030000`, `20261016040000`) | off |
| `CATPAW_AGENT_MEMORY_ENABLED` | `true` · `allowlist` · unset/off (Wave 2 B1, needs migration `20261016090000`) | off |
| `CATPAW_DEVICE_TOOLS_ENABLED` | `true` · `allowlist` · unset/off (Wave 2 B3, catpaw.device.v1; no migration) | off |
| `CATPAW_FEATURE_ALLOWLIST_SUBJECTS` | comma-separated auth user UUIDs (demo/staging accounts) | empty |

- `allowlist` offers the tool only when `turn.subject_id` is in the list. Everyone else gets today's behaviour.
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
