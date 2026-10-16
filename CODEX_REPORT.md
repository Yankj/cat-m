# CatpawM widgets, notifications, and Live Activity implementation report

Date: 2026-10-16 (Asia/Shanghai)

## Source identity

- Branch: `feat/widgets-notify`
- Starting commit: `1632deb058fff4809453ef9b80eaf170647a4347`
- Configured upstream: `origin/feat/ios-mvp-integration-v2` (the local branch was 0 ahead / 5 behind before this commit)
- App version compiled: `0.3.0 (39)`
- A pre-existing modification to `.eden/quickstart/prd.md` was preserved and excluded from this implementation and commit.

## Delivered behavior

- Replaced the demo task/status home widgets with focused next-suggestion and next-meeting widgets. Populated views show a primary title and an explicit why line; missing, corrupt, or older snapshots render truthful empty states.
- Added a version-2 minimal widget snapshot projection for the next pending suggestion and earliest projected meeting. The writer remains atomic and reloads WidgetKit timelines.
- Applied the requested deep links: next suggestion and suggestion-oriented Lock Screen states use `catpawm://proactive`; next meeting and meeting continuation use `catpawm://new`.
- Polished the Lock Screen accessory families with monochrome-compatible SF Symbols and a compact why line in the rectangular family.
- Replaced the custom illustrated cat Live Activity with a professional status system: warm off-white Lock Screen surface, restrained orange accent, semantic SF Symbols, explicit status labels, and a three-phase progress track. Activity lifecycle, token registration, content-state mapping, and conversation deep linking are unchanged.
- Registered Create reminder, Snooze, and Not now proactive notification actions. All three resolve a stable suggestion and execute through `ProactiveSuggestionStore` / `ProactiveSuggestionBackend`; Not now maps to the existing dismiss action. Default taps route to the proactive inbox, while custom dismiss and unknown identifiers do not create effects.
- Added stable metadata to pre-scheduled meeting notifications so cold-start actions can recover the exact meeting suggestion. Foreground proactive banners now also link to the proactive inbox.

## Changed files

- `apps/ios-conversation/Widgets/CatpawWidgets/CatpawHomeWidgets.swift`
- `apps/ios-conversation/Widgets/CatpawWidgets/CatpawWorkLiveActivity.swift`
- `apps/ios-conversation/Sources/App/CatpawPushNotifications.swift`
- `apps/ios-conversation/Sources/Features/Proactive/ProactiveEngine.swift`
- `CODEX_REPORT.md`

No backend, database, model, authentication, deployment, conversation UI, package, or historical application source was changed.

## Verification

PASS:

```sh
xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj \
  -scheme CatpawM -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/catpawm-widgets-dd \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `BUILD SUCCEEDED`; the `CatpawWidgets` extension compiled and embedded in the simulator app. Existing Swift 6 isolation and EventKit/audio deprecation warnings remain; no new build error or warning category was introduced by this slice.

PASS:

```sh
zsh apps/ios-conversation/Scripts/check-source.sh
python3 scripts/check-repository-layout.py
python3 scripts/check-repository.py
python3 scripts/check-deployed-source.py
git diff --check
```

The native source gate passed project membership, localization, non-Debug Simulator SDK typecheck, and syntax parsing. Repository layout, frozen source/provenance, and deployed-source snapshot identity passed.

Sensitivity scan:

```sh
python3 scripts/scan-repository.py
```

The scan found zero blocking hits. It exited 1 for eight unchanged manual-review matches outside this patch: six image-set filenames containing scale suffixes, one repository SSH allowlist literal, and one synthetic test-key literal. Manual review confirmed these are filenames or test/governance fixtures, not credentials or personal data; the unrelated reviewed-findings baseline was not modified.

## Evidence limits

- This is simulator compilation and static verification, not physical-device or product acceptance.
- No widget gallery/Lock Screen pixels, notification delivery/action execution, EventKit reminder write, Live Activity presentation, Dynamic Island presentation, VoiceOver, or maximum Dynamic Type path was executed on a device.
- The existing App Group identifier remains unprovisioned in this checkout. The versioned snapshot code compiles, but real cross-process widget data requires a valid shared entitlement/profile and separate device evidence; without it, widgets intentionally show their empty state.
- No model/Auth request, deployment, device installation, permission prompt, or server write was performed.
- This slice does not close AF-A15, AF-A17, AF-U10–12, FINAL-G1, or FINAL-G3.
