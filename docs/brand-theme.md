# Catpaw-m brand & theme

Single source of truth for palette and logo. Brand sheet refs live in `docs/refs/brand/`.

## Architecture

| Layer | Where | Role |
| --- | --- | --- |
| Hex tokens | `Sources/DesignSystem/CatpawBrandTokens.swift` | Raw brand sheet values (`primary`, `deep`, `background`, `ink`, `grey`, derived) |
| Semantic colors | `CatpawColors` in `Components.swift` | `ink`, `secondary`, `fill`/`action`/`primary`, `attention`, calm/orb roles — **use these at call sites** |
| Identity alias | `CatpawBrand` in `CatpawMotion.swift` | `paw` → `CatpawColors.fill`; clay roles for presence animation |
| Mark view | `BrandMark` | Cat-head asset wrapper (template / fill / onOrange) |
| Assets | `Resources/Assets.xcassets/CatpawBrand/` | `BrandMark*`, `LaunchPaw*`, `LaunchFirstFrame`, `LaunchGlow` |
| App icon | `Assets.xcassets/AppIcon.appiconset` | Soft 3D white-on-orange hero (stays at catalog root) |
| Launch canvas | `LaunchCanvas.colorset` + storyboard | Warm background `#FFFCF8` |

Composer send/stop morph and voice-capsule chrome are owned by the Mac worker — do not reshape them here. They may keep reading `CatpawBrand.paw` (now an alias of `fill`).

## Brand sheet (2026-10)

- Primary `#FF702A` → fills / icons only (never body text)
- Deep `#C64A0B` → `actionText` when orange text is unavoidable
- Background `#FFFCF8`
- Ink `#292622`
- Grey `#929298`
- Mark: soft 3D cat-head for App Icon / splash; flat fill / reverse for in-app chrome
- Composer placeholder:「有什么我可以帮你？」
- Subtitle:「你的个人 AI 助手」
- Slogan (string ready, not a new screen):「把交代的事，变成可用成果。」

## Accessibility mapping

| Sheet swatch | Semantic role (light) | Why |
| --- | --- | --- |
| Primary `#FF702A` | App Icon, `BrandMarkFill`, `orbDeep` / glow | Exact brand mark |
| Deep `#C64A0B` | `CatpawColors.fill` / `action` (`fillLight`) | ≥3:1 (non-text) on Background |
| Grey `#929298` | `CatpawColors.tertiary` (muted) | Placeholders / chrome |
| Grey → `#6E6A66` | `CatpawColors.secondary` (`secondaryLight`) | ≥4.5:1 secondary text on Background/panel |
| Ink `#292622` | `CatpawColors.ink` | Primary text |

## How to swap the palette later

1. Edit hex constants in `CatpawBrandTokens` only.
2. Rebuild. `CatpawColors` / `CatpawBrand` pick up the new values automatically.
3. If contrast fails WCAG for `actionText`, adjust `deep` / `deepDark` — do not recolor body copy to orange.
4. Run `Scripts/check-native-design.py` (and typography / localization / repository checks).

## How to swap the logo later

1. Drop new masters into `docs/refs/brand/` (3D hero, flat-on-black, brand sheet).
2. Regenerate PNGs into `Assets.xcassets/CatpawBrand/` and `AppIcon.appiconset` (see script notes in that folder or re-run the brand asset generator used for this PR).
3. Keep asset **names** (`BrandMark`, `BrandMarkFill`, `BrandMarkOnOrange`) so `BrandMark` view stays unchanged.
4. Prefer `BrandMark` over `PawMark` for identity surfaces. `PawMark` remains for pastel category markers only.

## Do / don’t

- Do: `CatpawColors.ink`, `.secondary`, `.fill`, `.attention`, `BrandMark(...)`.
- Don’t: raw `Color(UIColor(rgb: 0x…))` / magic oranges at feature call sites.
- Don’t: orange body text; orange is fill/icon only.
