// first-run-polish: portable checks for the splash/onboarding appearance contract (FirstRunAppearance.swift).
// Contrast is computed against the REAL brand/semantic tokens, parsed from catBrandTokens.swift and Components.swift,
// in both light and dark (the splash follows the system scheme like chat). Run: Scripts/test-first-run-portable.sh
import Foundation

nonisolated(unsafe) var missing = Set<String>()
struct Tokens {
    var brand: [String: UInt32] = [:]
    var adaptive: [String: (UInt32, UInt32)] = [:]
    init(root: String) {
        let b = (try? String(contentsOfFile: root + "/Sources/DesignSystem/catBrandTokens.swift", encoding: .utf8)) ?? ""
        for m in b.matches(of: #/static let (\w+): UInt32 = 0x([0-9A-Fa-f]{6})/#) { brand[String(m.1)] = UInt32(m.2, radix: 16)! }
        let c = (try? String(contentsOfFile: root + "/Sources/DesignSystem/Components.swift", encoding: .utf8)) ?? ""
        func v(_ s: Substring) -> UInt32 { s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16)! : brand[String(s.split(separator: ".").last!)]! }
        for m in c.matches(of: #/static let (\w+) = adaptive\(light: ([\w.]+), dark: ([\w.]+)\)/#) { adaptive[String(m.1)] = (v(m.2), v(m.3)) }
    }
    func resolve(_ t: FirstRunAppearance.Token, _ s: FirstRunAppearance.Scheme) -> UInt32 {
        switch t {
        case .color(let n): guard let p = adaptive[n] else { missing.insert(n); return 0 }; return s == .light ? p.0 : p.1
        case .brand(let n): guard let v = brand[n] else { missing.insert(n); return 0 }; return v
        case .hex(let h): return h
        }
    }
}

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL", msg) } }

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let tokens = Tokens(root: root)
check(!tokens.brand.isEmpty && !tokens.adaptive.isEmpty, "tokens parsed")

print("| text | scheme | fg | bg (worst case) | ratio | need |")
for s in FirstRunAppearance.Scheme.allCases {
    for spec in FirstRunAppearance.texts {
        let fg = tokens.resolve(spec.fg, s)
        var bg = tokens.resolve(spec.bg, s)
        if let (o, a) = spec.overlay { bg = FirstRunAppearance.composite(tokens.resolve(o, s), alpha: a, over: bg) }
        let fgEff = spec.fgAlpha < 1 ? FirstRunAppearance.composite(fg, alpha: spec.fgAlpha, over: bg) : fg
        let r = FirstRunAppearance.contrast(fgEff, bg), need = spec.large ? 3.0 : 4.5
        print(String(format: "| %@ | %@ | #%06X | #%06X | %.2f | %.1f |", spec.id, "\(s)", fgEff, bg, r, need))
        check(r >= need, "\(spec.id) \(s) \(String(format: "%.2f", r)) < \(need)")
        // No orange text: the foreground must not be a brand orange.
        check(![tokens.brand["primary"], tokens.brand["deep"], tokens.brand["primaryDark"], tokens.brand["deepDark"], tokens.brand["orbLight"]].contains(fg), "\(spec.id) uses orange text")
        // #929298 is for auxiliary icons only.
        check(fg != tokens.brand["grey"], "\(spec.id) uses brand grey #929298 as text")
    }
}
// Splash background == chat background in both schemes (no light→dark jump).
for s in FirstRunAppearance.Scheme.allCases {
    check(tokens.resolve(FirstRunAppearance.pageBackground, s) == tokens.resolve(.color("background"), s), "splash page background differs from chat in \(s)")
}
// Grok Bot 12:33: one dark canvas #0E0C0A for launch screen, splash and chat; light #FFFCF8.
check(tokens.resolve(.color("background"), .dark) == 0x0E0C0A && tokens.resolve(.color("background"), .light) == 0xFFFCF8, "chat canvas light #FFFCF8 / dark #0E0C0A")
check(tokens.resolve(.color("calmSecondary"), .light) == 0x5F5A55 && tokens.resolve(.color("calmSecondary"), .dark) == 0xB3ADA6, "splash secondary text #5F5A55 / #B3ADA6")
check(tokens.resolve(.color("calmCTATop"), .light) == 0xC9501A && tokens.resolve(.color("calmCTABottom"), .light) == 0xB8440A, "CTA gradient #C9501A → #B8440A")
// LaunchCanvas.colorset and LaunchBackground.colorset (the launch canvases) == the chat's first-frame colour in each mode.
for set in ["LaunchCanvas", "LaunchBackground"] {
do {
    let url = URL(fileURLWithPath: root + "/Resources/Assets.xcassets/\(set).colorset/Contents.json")
    let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
    var got: [String: UInt32] = [:]
    for c in (j?["colors"] as? [[String: Any]]) ?? [] {
        let comp = ((c["color"] as? [String: Any])?["components"] as? [String: String]) ?? [:]
        func h(_ k: String) -> UInt32 { let v = comp[k] ?? "0"; return v.hasPrefix("0x") ? UInt32(v.dropFirst(2), radix: 16)! : UInt32((Double(v) ?? 0) * 255 + 0.5) }
        let dark = ((c["appearances"] as? [[String: String]]) ?? []).contains { $0["value"] == "dark" }
        got[dark ? "dark" : "light"] = h("red") << 16 | h("green") << 8 | h("blue")
    }
    check(got["light"] == tokens.resolve(.color("background"), .light) && got["dark"] == tokens.resolve(.color("background"), .dark), "\(set) \(got) == chat background")
}
}
let storyboard = (try? String(contentsOfFile: root + "/Resources/Base.lproj/LaunchScreen.storyboard", encoding: .utf8)) ?? ""
// launch-v2 (replaces the B2 96 pt tile and the older "no logo" rule): the launch screen HAS a logo — the LaunchGlyph cat
// glyph 70×56 plus the system-font slogan, group centre at 0.61 H of the superview, on LaunchCanvas — identical to
// catLaunchStatic's first frame.
check(storyboard.contains("<image") && storyboard.contains("image=\"LaunchGlyph\""), "launch screen draws the LaunchGlyph logo")
check(storyboard.contains("name=\"LaunchCanvas\"") && storyboard.contains("name=\"LaunchSlogan\""), "launch screen on LaunchCanvas, slogan in LaunchSlogan")
check(storyboard.contains("constant=\"70\"") && storyboard.contains("constant=\"56\"") && storyboard.contains("multiplier=\"1.22\""), "glyph 70×56, group centre at 0.61 H")
check(storyboard.contains("id=\"SLG-01\"") && storyboard.contains("type=\"system\" pointSize=\"17\""), "slogan is system 17 text (SLG-01)")
for (lang, slogan) in [("en", "A step ahead. Things handled."), ("zh-Hans", "先你一步，把事办妥")] {
    let s = (try? String(contentsOfFile: root + "/Resources/\(lang).lproj/LaunchScreen.strings", encoding: .utf8)) ?? ""
    check(s.contains("\"SLG-01.text\" = \"\(slogan)\";"), "launch slogan localized \(lang)")
}
// Spec hygiene: no translucent text (the brand label used ink at 0.72).
for t in FirstRunAppearance.texts { check(t.fgAlpha == 1, "\(t.id) uses translucent text") }
for sch in [FirstRunAppearance.Scheme.light, .dark] {
    let r = FirstRunAppearance.contrast(tokens.resolve(.color("calmIcon"), sch), tokens.resolve(.color("calmSurface"), sch))
    print("  toast icon (non-text) \(sch) \(String(format: "%.2f", r))")
    check(r >= 3 && tokens.resolve(.color("calmIcon"), sch) == 0x929298, "toast icon #929298 ≥3:1 on surface \(sch)")
}
check(missing.isEmpty, "unknown tokens \(missing.sorted())")
// Transition choice.
check(FirstRunAppearance.transition(reduceMotion: true) == .crossfade(duration: 0.2), "reduce motion → short plain crossfade")
if case .spring(let response, let damping) = FirstRunAppearance.transition(reduceMotion: false) { check(response <= 0.5 && damping >= 0.8, "spring is quick and not bouncy") } else { check(false, "motion → spring") }
// Launch plan.
check(FirstRunAppearance.launch(reduceMotion: false, voiceOver: true) == .skip, "VoiceOver skips the launch animation")
check(FirstRunAppearance.launch(reduceMotion: true, voiceOver: false) == .fade(duration: 0.25), "reduce motion → short fade")
if case .full(let total) = FirstRunAppearance.launch(reduceMotion: false, voiceOver: false) { check(total <= 1.2, "launch ≤ 1.2 s (got \(total))") } else { check(false, "full launch") }
check(FirstRunAppearance.launchKeyframes.count <= 4, "few keyframes")

// SPEC-E (/workspace/codex-review/onboarding-motion/SPEC-E.md) — transition E + landing entrance + idle.
do {
    let e = FirstRunAppearance.handoff(reduceMotion: false)
    func t(_ id: String) -> FirstRunAppearance.Track? { e.first { $0.id == id } }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.011 } ?? false }
    // §2.2 start times (seconds after touch-down).
    let starts: [(String, Double)] = [("cta.press", 0), ("chips.fold0", 0.04), ("chips.fold7", 0.145), ("copy.fade", 0.06), ("glow.fade", 0.05),
        ("cat.squash", 0.06), ("cat.flight", 0.14), ("cat.crossfade", 0.40), ("cat.handoff", 0.68), ("cta.morph", 0.12), ("cta.fill", 0.12), ("cta.label", 0.12),
        ("composer.placeholder", 0.36), ("composer.add", 0.40), ("composer.mic", 0.44), ("composer.send", 0.48), ("chat.buttons", 0.38),
        ("chat.row0", 0.40), ("chat.row1", 0.44), ("chat.backdrop", 0.48), ("chat.title", 0.62)]
    for (id, s0) in starts { check(near(t(id)?.start, s0), "SPEC-E §2.2 \(id) starts at \(s0) (got \(t(id).map { "\($0.start)" } ?? "missing"))") }
    check(near(t("chips.fold0")?.end, 0.30) && near(t("copy.fade")?.end, 0.26) && near(t("glow.fade")?.end, 0.45) && near(t("cat.squash")?.end, 0.14) && near(t("cta.label")?.end, 0.30) && near(t("cta.fill")?.end, 0.42), "SPEC-E §2.2 fixed-duration ends")
    check(near(t("cat.flight")?.end, 0.75) && near(t("cta.morph")?.end, 0.62), "flight ~0.75, morph ~0.62")
    check((e.map(\.end).max() ?? 9) <= 1.15 && (e.map(\.end).max() ?? 0) >= 1.05, "E settles at ≈1.10–1.15 s after the tap")
    check(e.contains { $0.kind == .move }, "E moves")
    let rm = FirstRunAppearance.handoff(reduceMotion: true)
    check(rm.count == 2 && rm.allSatisfy { $0.kind == .fade } && near(rm.first { $0.id == "landing.fade" }?.start, 0.10) && near(rm.first { $0.id == "landing.fade" }?.end, 0.30)
          && near(rm.first { $0.id == "chat.fade" }?.start, 0.25) && near(rm.first { $0.id == "chat.fade" }?.end, 0.45), "§3 Reduce Motion: landing out 0.10–0.30, chat in 0.25–0.45, fades only")
    // §2.1 landing entrance.
    let en = FirstRunAppearance.entrance(reduceMotion: false)
    func n(_ id: String) -> FirstRunAppearance.Track? { en.first { $0.id == id } }
    let enStarts: [(String, Double)] = [("hero", 0.10), ("shadow", 0.10), ("glow", 0.20), ("brand", 0.35), ("brandSubtitle", 0.40), ("headline", 0.45), ("subtitle", 0.50),
        ("ring", 0.47), ("chip0", 0.60), ("chip7", 0.915), ("cta", 0.85), ("footer", 0.93), ("drift", 1.40), ("idle", 0.60)]
    for (id, s0) in enStarts { check(near(n(id)?.start, s0), "SPEC-E §2.1 \(id) at \(s0) (got \(n(id).map { "\($0.start)" } ?? "missing"))") }
    check(near(n("drift")?.end, 2.20), "chip drift fades in 1.4 → 2.2 s")
    check(FirstRunAppearance.chipDriftScale == 0.45, "chip drift at 45% amplitude")
    let enRM = FirstRunAppearance.entrance(reduceMotion: true)
    check(!enRM.isEmpty && enRM.allSatisfy { $0.kind == .fade && $0.start >= 0.149 && $0.end <= 0.351 }, "§3 Reduce Motion entrance: fades 0.15–0.35 only")
    // §2.3 idle.
    let idle = FirstRunAppearance.Idle.self
    check(idle.breathPeriod == 3.6 && idle.breathScaleY == 1.02 && idle.breathScaleX == 0.994 && idle.blinkEvery == 4.8 && idle.blinkDuration == 0.12
          && idle.tiltEvery == 5.2 && idle.tiltDegrees == 3 && idle.tiltDuration == 0.6 && idle.fps == 30, "§2.3 idle loop constants")
    check(FirstRunAppearance.heroSize == 120 && FirstRunAppearance.headerAvatarSize == 28, "hero 120 pt → header avatar 28 pt")
    // §1 chip icon colours (icon only, ≥3:1 non-text on the chip).
    check(tokens.resolve(.color("calmChipIcon"), .light) == 0xC64A0B && tokens.resolve(.color("calmChipIcon"), .dark) == 0xFF8A5C, "chip icon #C64A0B / #FF8A5C")
    for sch in [FirstRunAppearance.Scheme.light, .dark] {
        let r = FirstRunAppearance.contrast(tokens.resolve(.color("calmChipIcon"), sch), tokens.resolve(.color("calmSurface"), sch))
        print("  chip icon (non-text) \(sch) \(String(format: "%.2f", r))"); check(r >= 3, "chip icon ≥3:1 \(sch)")
    }
    let login = (try? String(contentsOfFile: root + "/Sources/Features/NativeLoginView.swift", encoding: .utf8)) ?? ""
    check(login.contains("FirstRunPlushHero(") && !login.contains("CalmOrb("), "landing centre is the plush hero, not the orange orb")
    // §6 asset: derived eyes-closed Front frame, pixel-aligned with MascotFront.
    let fm = FileManager.default, m = root + "/Resources/Assets.xcassets/catBrand/Mascot/"
    check(["MascotFrontBlink.imageset/Contents.json", "MascotFrontBlink.imageset/MascotFrontBlink@2x.png", "MascotFrontBlink.imageset/MascotFrontBlink@3x.png"].allSatisfy { fm.fileExists(atPath: m + $0) }, "MascotFrontBlink imageset (@2x/@3x)")
}
print(failures == 0 ? "first-run appearance: all passed" : "first-run appearance: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
