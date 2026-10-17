# Technical design: PR #20 + iOS MVP UI integration

## Repository evidence and compatibility boundary

The active merge has one textual conflict in `apps/ios-conversation/CatpawM.xcodeproj/project.pbxproj`. Index stage 2 adds four PR #20 sources (`ConversationOutbox`, `ConversationConnectionState`, `ConnectionMonitor`, and `DeveloperModelRouteSection`). Stage 3 adds eight UI sources and the complete `CatpawWidgets` extension, embed phase, and target dependency. All identifiers are disjoint. The resolved app source phase must contain 138 build-file identifiers; the widget source phase must contain two.

The current service and contracts already expose the required presentation seams: `ConversationSessionService.turnEvents()`, `continueFetching`, `retryBusy`, and `stopObserving`; `ConversationTurnEvent.Payload.reasoningSummary(...thinkingMs:)`; persisted `ConversationTurnRecord.reasoningSummary/thinkingMs`; and `ConnectionMonitor.shared` with published state and waiting operation IDs. These files are protected by the task and need no changes.

## Project merge resolution

Use the UI side as the structural target because it contains the widget product, target, configurations, extension phases, embed copy phase, app dependency, and project target-list entry. Preserve the PR #20 side’s four file-reference/build-file declarations and append their identifiers to the root group and CatpawM source phase. Preserve all eight UI source entries in the same group and source phase. Validate that `CatpawWidgets.appex` remains in Products, CatpawM keeps `Embed Foundation Extensions`, and CatpawM depends on `CatpawWidgets`.

## Presentation integration

### Phased answers

`AnswerPhaseProjection` becomes the lifecycle owner of a task consuming `service.turnEvents()`, filtered to its operation ID. It initializes from the persisted message/turn snapshot, then treats the live stream as authoritative. Snapshot reconciliation restores message text, reasoning summary, provider thinking duration, and terminal/interrupted phase without appending text repeatedly. A `.started` event resets per-turn presentation state. `.reasoningSummary` updates both visible summary and `thinkingMs`; provider duration is rounded up to seconds and backdates the visible timer. Existing sequence dedupe remains.

`LivePhasedAnswerView` receives the service, constructs the projection with service, operation, message, and turn, and reconciles on persisted content/state/error/reasoning changes. `ConversationFirstView` passes `model.service`.

### Composer state

`ConversationComposerChromeAdapter` starts one task consuming all turn events. It records operation IDs on `.started` and removes them on `.completed` or `.failed`. `runState` is `.responding` only when an active event-derived ID is present in the current session; it does not read `model.busy` or `model.sending`. Stop calls `stopObserving` for the current conversation, clears only current-session active IDs, and reports service errors through the model. Queue preview is gated by event-derived responding state.

### Connection and offline presentation

`ConversationFirstView` observes `ConnectionMonitor.shared`. A top safe-area capsule renders every non-online monitor state via its existing localized label, so `.busy(retryIn:)` automatically displays the monitor’s per-second countdown. `.unreachable` calls read-only `continueFetching`; `.busy` calls current-route `retryBusy(...automatic:false)`. Actions are disabled while in flight or without a conversation.

Under a user bubble, an operation in `waitingForNetwork` gets a `等待网络` label before its existing admission status. In `displayMessages`, fold duplicate user rows sharing an operation ID by retaining the first; non-user and unresolvable rows pass through unchanged.

## Preserved UI branch behavior

Do not alter the existing `-CatpawShowFixtureBadge` gate, `CatpawBrand.paw` send treatment, or `NativeConversationComposer` placeholder lifecycle and localized placeholder. The merge resolution must keep their source membership.

## Real simulator runner

Add executable `scripts/run-real-sim.sh` using zsh strict mode. Resolve repository root from the script location. Require the three named public runtime configuration variables using indirect expansion, print only missing names, and exit before building if any are absent. Build CatpawM Debug with the exact requested project, scheme, destination, and derived-data path. Verify/boot the exact simulator, uninstall the existing bundle only if installed, install `/tmp/catpaw-dd-merge/Build/Products/Debug-iphonesimulator/CatpawM.app`, and launch `com.example.CatpawM.ConversationFirst.Auth`.

At launch, strip inherited `SIMCTL_CHILD_*` variables and pass only `SIMCTL_CHILD_CATPAW_SUPABASE_PROJECT_URL`, `SIMCTL_CHILD_CATPAW_SUPABASE_PUBLISHABLE_KEY`, and `SIMCTL_CHILD_CATPAW_BACKEND_ORIGIN`. This matches the Debug-only `ProcessInfo.environment` reads in `NativeAuthApplicationModel`; no secret is written to plist, xcconfig, logs, or arguments printed by the script. Open Simulator only after a successful launch.

## Verification

1. Parse/validate the project and confirm CatpawM, tests, UI tests, and CatpawWidgets remain.
2. Run the exact requested simulator build until successful.
3. Run `apps/ios-conversation/Scripts/check-source.sh`, native design validation, repository layout/integrity/frozen-source/sensitivity checks, and `git diff --check`.
4. Inspect diffs to confirm protected files and `services/` remain unchanged and no secrets are present.
5. Report build/static evidence only; executing the runner or claiming real-backend acceptance is outside this task because credentials were neither requested nor supplied.
