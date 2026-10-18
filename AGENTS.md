# Catpaw-m workspace instructions

## Quick context (human + AI)

- Stack: Swift 5 / SwiftUI (iOS 17+), SwiftData, URLSession SSE, EventKit; backend Supabase Edge Functions (Deno) + PostgreSQL.
- Edit only `apps/ios-conversation` (native) and `services/edge/supabase/functions` (backend); other app/service roots are frozen sources.
- Layers: Views -> `*Service` -> Domain contracts; Providers wrap network/auth/system frameworks; Persistence wraps SwiftData.
- Domain: Conversation/Turn, TaskPlan, TaskAction (approval), TaskControl, DeviceEffect (calendar/notification), Artifact, Inbox, Memory, GenerativeUI.
- Overview: [README](README.md), [architecture](docs/architecture.md), [docs index](docs/README.md).

## Repository architecture and Git rules

- Directory roles are fixed by `docs/development/repository-layout.json`; read `docs/architecture/repository-review-2026-10-13.md` before restructuring. One active native App and one backend maintenance source; historical apps, deployed snapshots and pinned upstreams are separate roles, never competing maintenance roots.
- Use the short branches in `docs/development/branch-management.md`. Do not develop or commit directly on main. The temporary `docs/restart-design-integration` checkout holds the existing uncommitted restart documents; preserve other owners' edits and commit only an explicit reviewed path set.
- Never merge or push legacy-local history into origin. Selectively import reviewed bytes with provenance. Unmerged candidate branches must retain their original evidence layer; synthetic kernels or memory-only UI are not production implementations.
- UI calls application services through typed contracts; components do not own accounts, HTTP admission or task execution. Persistence/effect authority stays in the existing scoped backend; presentation and stream termination cannot grant authority or declare completion.
- New public design/research goes under docs/design or docs/research. Root design/research are retained source inputs; ignored build/local-audit contain runtime and private material. Do not duplicate specifications or live status.
- Before delivery run layout, frozen-source, relevant contract and sensitivity checks. Local hooks are available in `.githooks`; they guard CLI operations, not connector/API/UI writes. GitHub server enforcement is unavailable on the currently observed private-repository plan; do not claim it is active.

- Current Goal execution definition: docs/planning/AF-1/goal.md (AF-1-G3-UX1); interpret the running Goal's shorthand through this contract. Required closure includes all AF-A01–18, AF-U01–12 and CP-01–03 in one release. Sources and evidence limits are in goal-evidence-map.json; design lanes run alongside feature slices. Active restart authority remains docs/product/agent-foundation-spec.md, docs/acceptance/agent-foundation-acceptance.md and docs/status/delivery-slices.json. State only in docs/status/master-plan.md; preserve dated evidence.
- Save screenshots requested by the user with provenance and version. Private phone/reference captures stay under ignored local-audit/screenshots; synthetic proposal screenshots cannot close native acceptance. Historical design/research proposals do not expand current authorization or scope.
- The user has authorized migration into this workspace, GitHub synchronization and confirmed feature development. Preserve legacy worktrees and local-only history; read handoff.md for takeover scope.
- Cloud computer hosting is proposal-only until sustainable zero-additional-cost resources, provider and region are confirmed. The user chose existing Supabase first and an additional compute budget of zero; do not provision new paid compute or use trial credits as a permanent free plan. First scope is public web research and file processing without third-party account login. Continue unrelated confirmed work.
- Verify the existing model route before discussing a switch; do not change providers or paid fallback on your own. The user freshly approved the frozen a905b47 build 16 update on the existing iPhone and at most two short text checks through normal App consent. Later packages or expanded checks need concrete approval; preserve existing data.

- Read README, docs/status/master-plan.md and the applicable acceptance record before claiming completion. Maintain current progress only in the master plan; indexes link to it.
- Conversation-first is the current product direction. Historical v1/r2/r3 synthetic tests and repository preparation do not prove current product acceptance. Preserve the chosen A1 icon; peripheral r4 work is paused.
- Preserve delivered v1 and frozen spec/HTTP contract identity. Never overwrite an active independent client checkout.
- Keep synthetic results distinct from real model, cloud, SQL multi-instance and device verification.
- Preserve upstream MIT notices, the pinned source manifest and the exact controlled patch.
- Keep runtime output under ignored build/evidence directories; curate only synthetic evidence with version and hashes.
- Use existing tools without adding credentials or dependencies unless the user requests it.
- Run the repository integrity and sensitivity checks before preparing a commit. No push, PR or publication is authorized by repository instructions alone.

## Fixed local integration checkout

- Current native maintenance entry is `apps/ios-conversation/CatpawM.xcodeproj`; historical `apps/ios` and `apps/ios-openmuse-demo` remain frozen.
- Backend entry is `services/edge/supabase/functions/`; `packages/ios-navigation` and `packages/ios-image-composer` are checked-in local Swift packages connected to the native host; their independent tests do not replace host acceptance.
- Read `docs/README.md`, `docs/status/local-integration-source.json` and `docs/acceptance/local-fixed-directory.md` for checkout provenance and exact local validation scope.
- Do not import canonical untracked candidates/assets/research/tooling during routine work. Changes in other owner worktrees are not automatically present here.
- Offline checks use existing Xcode/Deno and an explicitly supplied public dependency cache. No dependency install, production config copy, Auth/model request, deployment, device install or push is implied.
- Preserve committed QA reports as dated evidence for their pinned inputs. Their prepare/collect scripts rewrite reports; use a separate execution copy for new QA runs.
