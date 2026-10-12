# iOS build15 physical test-candidate installation

2026-10-12. Following explicit installation-for-testing authorization, the signed frozen `4750142e9999bcf39a2231bd321169fe73e5e014` candidate was actually installed over the original iPhone13 App. This supersedes the earlier no-install checkpoint, not its historical evidence. Full product release is not claimed.

## Actual result

`devicectl device install app` and normal `device process launch` both returned success. A new physical device app inventory reads bundle `com.example.CatpawM.OpenMuseDemo`, version0.3.0, build15. The launched process has no fixture/scenario/login overrides. Same original certificate/profile/entitlements and public connection values were verified in the [signed package report](ios-signed15-v19-20261012.md). No uninstall/data reset, credential export, new identity/profile or system permission change occurred.

Private physical screenshot shows the original conversation restored and a text-cloud-model consent alert awaiting action. No permission was confirmed and no image was sent. Screenshot is internal inspection only and is not published or included in Library; the structured [RESULT.json](evidence/ios-build15-install-20261012/RESULT.json) records its hash without personal conversation text. Existing App state is visibly retained; this is not a full database migration audit or final product acceptance.

## Real image end-to-end: NOT_RUN

Vision now live_configured on v19; disabled is no longer the blocker. Independent fixed475 QA `5485aa31e60d42d13a47dbb139d8d5480eb36a05` has8/8 actual TCP/URLSession loopback PASS and zero real model/Auth/image calls. Its exact wire boundaries remain separate from physical UI and live model acceptance.

Current remaining operational blocker: installed standard `devicectl` can install/launch/capture but cannot tap/type/select a photo. The phone has no existing XCTest/WDA runner, and only the original App provisioning profile is cached. Existing Mac AX authorization was checked without prompting and the installed Accessibility Inspector was explored, but no reliable physical-phone input channel was established. No new permission or runner profile was requested. No model command remains running and there has been no live image model call.

The next real test must use this normal App and existing login. Defer the old pending text permission first to preserve that prior question, then open a separate test conversation, use the authorized owned synthetic PNG, review its independent image consent/non-sensitive confirmation and press explicit Send. Record provider/attachment hash/zero-cost/terminal receipts and pixel semantics, then a text follow-up. Do not create another identity, export a token, replace the client with a CLI provider call or count loopback as this result. Until an authorized physical UI operator/tool performs these actions, report the real image chain as unverified.

IPA Library ID `libfile_5266b37675588191830e1fad1c867046`; local signed App and IPA paths are retained in the task handoff. Source code remains frozen4750142; subsequent commits change documentation only.
