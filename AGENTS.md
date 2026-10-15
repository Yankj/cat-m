# Catpaw-m workspace instructions

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
