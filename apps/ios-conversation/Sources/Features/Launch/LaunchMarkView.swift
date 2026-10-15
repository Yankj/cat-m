import SwiftUI
import UIKit

/// Cold-start paw animation (design.md §9.1, ≤1.4s). Runs in parallel with first-screen restore; never blocks it.
/// Timeline: toes pop 100ms + 70ms stagger → pad 380ms with 16% brand glow → wordmark 620ms → fade/scale-out 1050ms.
/// Skip: warm start, notification/deep-link launch, VoiceOver. Reduce Motion: 0.2s cross-fade only.
@MainActor struct LaunchMarkView: View {
    /// True when restore isn't finished at 1.4s; shows "正在恢复你的工作…" under the wordmark and holds the mark.
    var restoring: Bool
    var onFinished: () -> Void
    @State private var toes = [false, false, false, false]
    @State private var pad = false
    @State private var wordmark = false
    @State private var exiting = false
    @State private var showRestoring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .largeTitle) private var markSize = 88.0

    var body: some View {
        ZStack {
            CatpawColors.background.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(CatpawBrand.paw.opacity(pad ? 0.16 : 0)).frame(width: markSize * 1.6, height: markSize * 1.6).blur(radius: 18)
                    ForEach(0..<4, id: \.self) { i in
                        PawShape(part: PawShape.Part.allCases[i]).fill(CatpawBrand.paw)
                            .scaleEffect(toes[i] ? 1 : 0.2).offset(y: toes[i] ? 0 : 6).opacity(toes[i] ? 1 : 0)
                    }
                    PawShape(part: .pad).fill(CatpawBrand.paw).scaleEffect(pad ? 1 : 0.3).opacity(pad ? 1 : 0)
                }
                .frame(width: markSize, height: markSize)
                VStack(spacing: 10) {
                    Text(verbatim: "Catpaw").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(CatpawColors.ink)
                    if showRestoring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AppLanguage(locale: locale).ui("正在恢复你的工作…")).font(CatpawTypography.Role.caption.font)
                        }.foregroundStyle(CatpawColors.secondary).transition(.opacity)
                    }
                }
                .opacity(wordmark ? 1 : 0).offset(y: wordmark ? 0 : 8)
            }
            .scaleEffect(exiting ? 1.04 : 1)
        }
        .opacity(exiting ? 0 : 1)
        .accessibilityHidden(true)
        .task { await run() }
        .onChange(of: restoring) { _, value in if !value && showRestoring { Task { await exit() } } }
    }

    private func run() async {
        if reduceMotion {
            toes = [true, true, true, true]; pad = true; wordmark = true
            try? await Task.sleep(nanoseconds: 200_000_000)
            await exit(); return
        }
        let pop = Animation.spring(response: 0.34, dampingFraction: 0.55)
        try? await Task.sleep(nanoseconds: 100_000_000)
        for i in 0..<4 {
            withAnimation(pop) { toes[i] = true }
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        try? await Task.sleep(nanoseconds: 70_000_000)                  // ≈380ms
        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { pad = true }
        try? await Task.sleep(nanoseconds: 240_000_000)                 // ≈620ms
        withAnimation(.easeOut(duration: 0.4)) { wordmark = true }
        try? await Task.sleep(nanoseconds: 430_000_000)                 // ≈1050ms
        if restoring { withAnimation(.easeOut(duration: 0.2)) { showRestoring = true }; return }
        await exit()
    }

    private func exit() async {
        withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 0.36)) { exiting = true }
        try? await Task.sleep(nanoseconds: reduceMotion ? 200_000_000 : 360_000_000)
        onFinished()
    }
}

/// Decide once per process whether to play. Integration in `CatpawApp`/`RootView`:
/// `if LaunchMarkGate.shouldPlay(openedFromURL: …) { overlay LaunchMarkView }`.
@MainActor enum LaunchMarkGate {
    private static var played = false
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool {
        defer { played = true }
        return !played && !openedFromURLOrNotification && !UIAccessibility.isVoiceOverRunning
    }
}
