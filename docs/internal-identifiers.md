# Internal identifiers (intentionally kept)

The product is called **cat**. Some internal identifiers still use the old
`catpaw` name. They are left on purpose: renaming them would mean database
migrations, redeploys, new keys, or broken installs, and users never see them.

| Kind | Examples |
|---|---|
| Edge functions | `catpaw-api`, `catpaw-proactive` |
| Database roles / schemas | `catpaw_runtime`, `catpaw_records`, `catpaw_*` |
| Environment variables / feature flags | `CATPAW_FAMILY_ENABLED`, `CATPAW_FEATURE_ALLOWLIST_SUBJECTS`, `CATPAW_*` |
| Protocols / HTTP headers | `catpaw.family.v1`, `X-Catpaw-*` |
| Bundle ids / URL schemes | `com.example.CatpawM.*`, `catpawm://` |
| Xcode targets, types, and file names | `CatpawM*`, `Catpaw*` Swift types, `CatpawM.xcodeproj` references, `catpaw-*` spec files |
| Historical release artifacts | `Catpaw-<version>.ipa`, `Catpaw-<version>-simulator.zip` |

Git history before the rename also keeps the old name.

Supabase project refs in docs and examples are shown as `<your-project-ref>`.
Put your own value in `Local.xcconfig` (copied from `Local.xcconfig.example`).
