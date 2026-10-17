import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Single source of truth for Catpaw-m brand hex values (brand sheet 2026-10).
/// Sheet swatches stay exact. Semantic UI roles that need WCAG contrast derive from them
/// (`fillLight`, `secondaryLight`) so call sites never hardcode magic oranges/greys.
/// See `docs/brand-theme.md`.
enum CatpawBrandTokens {
    // Brand sheet swatches (exact)
    static let primary: UInt32 = 0xFF702A
    static let deep: UInt32 = 0xC64A0B
    static let background: UInt32 = 0xFFFCF8
    static let ink: UInt32 = 0x292622
    static let grey: UInt32 = 0x929298

    /// Light-mode UI fill: Deep meets ≥3:1 (actually ≥4.5) on Background.
    /// Sheet Primary stays on App Icon / `BrandMarkFill` / orb glow.
    static let fillLight: UInt32 = 0xC64A0B  // == deep; literal so design guard can resolve
    /// Light-mode secondary text: darkened brand Grey to clear 4.5:1 on Background.
    static let secondaryLight: UInt32 = 0x6E6A66  // accessible on panel/card/drawer (≥4.5)

    // Dark-mode / supporting (centralized)
    static let primaryDark: UInt32 = 0xFF8A5C
    static let deepDark: UInt32 = 0xFF9E78
    static let inkDark: UInt32 = 0xF2F0ED
    static let greyDark: UInt32 = 0xA39E98
    static let orbLight: UInt32 = 0xFF9A5C
    static let peach: UInt32 = 0xFFB894
    static let lavender: UInt32 = 0xD6CCFA
    static let clayShadow: UInt32 = 0x8A3A12
    static let panelLight: UInt32 = 0xF7F7F7
    static let panelDark: UInt32 = 0x181818
    static let canvasDark: UInt32 = 0x0E0C0A  // SPEC-E unified dark canvas (LaunchScreen = landing = chat)
}
