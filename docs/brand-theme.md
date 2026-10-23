# mimi brand & theme

Single source of truth for palette and logo. Brand sheet refs live in `docs/refs/brand/`.

## Architecture

| Layer | Where | Role |
| --- | --- | --- |
| Hex tokens | `Sources/DesignSystem/catBrandTokens.swift` | Raw brand sheet values (`primary`, `deep`, `background`, `ink`, `grey`, derived) |
| Semantic colors | `catColors` in `Components.swift` | `ink`, `secondary`, `fill`/`action`/`primary`, `attention`, calm/orb roles — **use these at call sites** |
| Identity alias | `catBrand` in `catMotion.swift` | `paw` → `catColors.fill`; clay roles for presence animation |
| Mark view | `BrandMark` | Cat-head asset wrapper (template / fill / onOrange) |
| Assets | `Resources/Assets.xcassets/catBrand/` | `BrandMark*`, `LaunchFirstFrame` (orange orb + white mark) |
| App icon | `Assets.xcassets/AppIcon.appiconset` | Soft 3D white-on-orange hero (stays at catalog root) |
| Launch canvas | `LaunchCanvas.colorset` + storyboard | Warm background `#FFFCF8` |

Composer send/stop morph and voice-capsule chrome are owned by the Mac worker — do not reshape them here. They may keep reading `catBrand.paw` (now an alias of `fill`).

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
| Deep `#C64A0B` | `catColors.fill` / `action` (`fillLight`) | ≥3:1 (non-text) on Background |
| Grey `#929298` | `catColors.tertiary` (muted) | Placeholders / chrome |
| Grey → `#6E6A66` | `catColors.secondary` (`secondaryLight`) | ≥4.5:1 secondary text on Background/panel |
| Ink `#292622` | `catColors.ink` | Primary text |

## Header cat

- Soft-3D clay head beside the chat title: `catPresence` (`docs/refs/header-cat/six-states.png`).
- Do **not** use flat `BrandMark` in the header capsule.
- Connection: offline → ears-down; error → wobble; thinking/working → orbit-load; streaming → spin; done → happy; else idle.

## Launch splash

- Static `LaunchScreen.storyboard` shows `LaunchFirstFrame`: cream `LaunchCanvas` + orange orb with white cat-head (`BrandMarkOnOrange`).
- Animated `LaunchMarkView` uses `BrandMark` only (`.fill` → merge `.onOrange`). No jelly / 4-pad paw on splash.
- Obsolete imagesets removed: `LaunchPaw`, `LaunchPawMark`, `LaunchGlow`. Do not regenerate them.
- Regenerate the static frame: `python3 apps/ios-conversation/design/brand/render_brand.py apps/ios-conversation/Resources/Assets.xcassets`.

## How to swap the palette later

1. Edit hex constants in `catBrandTokens` only.
2. Rebuild. `catColors` / `catBrand` pick up the new values automatically.
3. If contrast fails WCAG for `actionText`, adjust `deep` / `deepDark` — do not recolor body copy to orange.
4. Run `Scripts/check-native-design.py` (and typography / localization / repository checks).

## How to swap the logo later

1. Drop new masters into `docs/refs/brand/` (3D hero, flat-on-black, brand sheet).
2. Regenerate PNGs into `Assets.xcassets/catBrand/` and `AppIcon.appiconset` (see script notes in that folder or re-run the brand asset generator used for this PR).
3. Keep asset **names** (`BrandMark`, `BrandMarkFill`, `BrandMarkOnOrange`) so `BrandMark` view stays unchanged.
4. Prefer `BrandMark` over `PawMark` for identity surfaces. `PawMark` remains for pastel category markers only.

## Do / don’t

- Do: `catColors.ink`, `.secondary`, `.fill`, `.attention`, `BrandMark(...)`.
- Don’t: raw `Color(UIColor(rgb: 0x…))` / magic oranges at feature call sites.
- Don’t: orange body text; orange is fill/icon only.

## App Icon regeneration

Master: `docs/refs/brand/01-icon-hero-3d.png` (soft 3D white cat-head on `#FF702A`).

```bash
# light + dark (1024×1024)
sips -s format png -z 1024 1024 docs/refs/brand/01-icon-hero-3d.png \
  --out apps/ios-conversation/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-light.png
cp apps/ios-conversation/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-light.png \
   apps/ios-conversation/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-dark.png
# tinted = white BrandMarkOnOrange on black (see Scripts/regenerate-appicon.py)
python3 apps/ios-conversation/design/brand/regenerate_appicon.py
```

After installing a build that changes `AppIcon.appiconset`, **delete the app from the simulator/device before reinstalling**. SpringBoard caches the home-screen / app-switcher icon; a plain reinstall often keeps the old jelly paw.

## Obsolete jelly 4-toe assets (removed)

Do **not** restore these imagesets or design SVGs:

- `Assets.xcassets/catpaw.paw*.imageset` (app + Widgets)
- `design/symbols/catpaw.paw*.svg`
- `LaunchPaw` / `LaunchPawMark` / `LaunchGlow`

In-app identity: `BrandMark` / `LaunchFirstFrame` / soft-3D `catPresence` only. `PawMark` / `CategoryPaw` remain as **pastel category markers** (not the App Icon).

