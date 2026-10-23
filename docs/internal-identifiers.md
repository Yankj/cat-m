# Internal identifiers (intentionally kept)

The product is called **mimi** (Chinese: **小咪**). It was called Catpaw, then cat.
Some internal identifiers still use the old `catpaw` or `cat` names. They are left on purpose: renaming them would mean database
migrations, redeploys, new keys, or broken installs, and users never see them.

| Kind | Examples |
|---|---|
| Edge functions | `catpaw-api`, `catpaw-proactive` |
| Database roles / schemas | `catpaw_runtime`, `catpaw_records`, `catpaw_*` |
| Environment variables / feature flags | `CATPAW_FAMILY_ENABLED`, `CATPAW_FEATURE_ALLOWLIST_SUBJECTS`, `CATPAW_*` |
| Protocols / HTTP headers | `catpaw.family.v1`, `X-Catpaw-*` |
| Bundle ids / URL schemes | `com.example.CatpawM.*`, `catpawm://` |
| Xcode project, targets, schemes, types, and file names | `cat.xcodeproj`, scheme `cat`, `cat*` / `Catpaw*` Swift types and files (`catApp.swift`, `catNavigation`, `catImageComposer`, `catWidgets`), `CatpawM*` references, `catpaw-*` spec files |
| Website asset and storage keys | `assets/cat-*.webp`, `catpaw-product-deck.pdf`, `catpaw-theme` |
| Historical release artifacts | `Catpaw-<version>.ipa`, `Catpaw-<version>-simulator.zip` |

The GitHub repository was renamed from `Yankj/cat-m` to `Yankj/mimi` on 2026-10-23; GitHub redirects old URLs.
Git history before the rename also keeps the old names.

Supabase project refs in docs and examples are shown as `<your-project-ref>`.
Put your own value in `Local.xcconfig` (copied from `Local.xcconfig.example`).
