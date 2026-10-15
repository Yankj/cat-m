# iOS MVP UI integration onto PR #20

## Objective

Complete the already-running no-commit merge of `feat/ios-mvp-ui` into the PR #20 integration checkout, preserving every source from both merge sides and the `CatpawWidgets` target/embed, then port the behavior previously implemented by commit `6fd87df` onto the current PR #20 APIs.

## Fixed scope and decisions

- Work directly without another confirmation; the user has pre-confirmed implementation.
- Resolve only the existing `apps/ios-conversation/CatpawM.xcodeproj/project.pbxproj` merge conflict. Preserve all project sources from both sides, including the `CatpawWidgets` target and its embed phase.
- `AnswerPhaseProjection` subscribes to `service.turnEvents()` and handles `.reasoningSummary`, including `thinkingMs`.
- Composer stop/run state is projected from turn events rather than `model.busy`.
- The connection capsule observes `ConnectionMonitor.shared`; unreachable state offers `continueFetching`, and busy retry state shows a countdown.
- Show `等待网络` beneath bubbles while the answer phase is `waitingForNetwork`.
- Preserve the duplicate-operation-ID fold fallback from the prior integration.
- Preserve UI-branch fixes: fixture badge appears only with `-CatpawShowFixtureBadge`, the send control remains paw-orange, and the composer placeholder remains intact.
- Adapt all ports to the current PR #20 contracts instead of reverting protected backend/service APIs.
- Do not edit `NativeChatHTTPBackend`, `ConversationSessionService`, `ConversationSessionContracts`, `ConversationConnectionState`, `ConnectionMonitor`, `NativeAuthApplicationModel`, or any path under `services/`.
- Add `scripts/run-real-sim.sh`, written for zsh, requiring `CATPAW_SUPABASE_PROJECT_URL`, `CATPAW_SUPABASE_PUBLISHABLE_KEY`, and `CATPAW_BACKEND_ORIGIN`. Missing variables fail clearly; values are never printed.
- The runner builds Debug, uninstalls and reinstalls on simulator `9A4BC49A-CCE4-45D6-A1DC-6F072236DAB6`, launches with configuration passed through matching `SIMCTL_CHILD_` names used by the application, and opens Simulator with `open -b com.apple.dt.Devices`.
- Commit no secrets and create no Git commit.

## Verification

The following command must succeed before delivery:

```sh
xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj -scheme CatpawM -destination 'platform=iOS Simulator,id=9A4BC49A-CCE4-45D6-A1DC-6F072236DAB6' -derivedDataPath /tmp/catpaw-dd-merge build
```

Run repository layout, frozen-source, relevant contract/source, and sensitivity checks required by repository policy. Report exact changed file and line evidence, without claiming real-backend or physical-device acceptance.
