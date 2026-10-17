// first-run-polish: portable checks for the splash/onboarding appearance contract (FirstRunAppearance.swift).
// Contrast is computed against the REAL brand/semantic tokens, parsed from CatpawBrandTokens.swift and Components.swift,
// in both light and dark (the splash follows the system scheme like chat). Run: Scripts/test-first-run-portable.sh
import Foundation

struct Tokens {
    var brand: [String: UInt32] = [:]
    var adaptive: [String: (UInt32, UInt32)] = [:]
    init(root: String) {
        let b = (try? String(contentsOfFile: root + "/Sources/DesignSystem/CatpawBrandTokens.swift", encoding: .utf8)) ?? ""
        for m in b.matches(of: #/static let (\w+): UInt32 = 0x([0-9A-Fa-f]{6})/#) { brand[String(m.1)] = UInt32(m.2, radix: 16)! }
        let c = (try? String(contentsOfFile: root + "/Sources/DesignSystem/Components.swift", encoding: .utf8)) ?? ""
        func v(_ s: Substring) -> UInt32 { s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16)! : brand[String(s.split(separator: ".").last!)]! }
        for m in c.matches(of: #/static let (\w+) = adaptive\(light: ([\w.]+), dark: ([\w.]+)\)/#) { adaptive[String(m.1)] = (v(m.2), v(m.3)) }
    }
    func resolve(_ t: FirstRunAppearance.Token, _ s: FirstRunAppearance.Scheme) -> UInt32 {
        switch t {
        case .color(let n): let p = adaptive[n]!; return s == .light ? p.0 : p.1
        case .brand(let n): return brand[n]!
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
// Transition choice.
check(FirstRunAppearance.transition(reduceMotion: true) == .crossfade(duration: 0.2), "reduce motion → short plain crossfade")
if case .spring(let response, let damping) = FirstRunAppearance.transition(reduceMotion: false) { check(response <= 0.5 && damping >= 0.8, "spring is quick and not bouncy") } else { check(false, "motion → spring") }
// Launch plan.
check(FirstRunAppearance.launch(reduceMotion: false, voiceOver: true) == .skip, "VoiceOver skips the launch animation")
check(FirstRunAppearance.launch(reduceMotion: true, voiceOver: false) == .fade(duration: 0.25), "reduce motion → short fade")
if case .full(let total) = FirstRunAppearance.launch(reduceMotion: false, voiceOver: false) { check(total <= 1.2, "launch ≤ 1.2 s (got \(total))") } else { check(false, "full launch") }
check(FirstRunAppearance.launchKeyframes.count <= 4, "few keyframes")

print(failures == 0 ? "first-run appearance: all passed" : "first-run appearance: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
