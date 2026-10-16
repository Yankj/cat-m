import SwiftUI
import AVFoundation
import UIKit

/// 毛绒小伙伴 plush mascot (`Assets.xcassets/CatpawBrand/Mascot/`).
/// Six poses: 等待 · 思考 · 写回复 · 执行 · 完成 · 出错. Reduce Motion → still pose.
enum PlushMascotPose: String, CaseIterable, Equatable {
    case idle, thinking, writing, executing, done, error

    /// Connection + turn presence → plush pose.
    init(_ state: CatpawPresenceState) {
        switch state {
        case .waiting: self = .idle
        case .thinking: self = .thinking
        case .streaming: self = .writing
        case .working: self = .executing
        case .done: self = .done
        case .error, .offline: self = .error
        }
    }

    var assetName: String {
        switch self {
        case .idle: "MascotIdle"
        case .thinking: "MascotThinking"
        case .writing: "MascotWriting"
        case .executing: "MascotExecuting"
        case .done: "MascotDone"
        case .error: "MascotError"
        }
    }

    /// Bundled HEVC-with-alpha loop (`Resources/Mascot/<asset>.mov`), if shipped for this pose.
    var clipURL: URL? { Bundle.main.url(forResource: assetName, withExtension: "mov") }

    /// zh source key for the header status line.
    var statusKey: String {
        switch self {
        case .idle: "在这里等你"
        case .thinking: "正在思考"
        case .writing: "正在写回复"
        case .executing: "正在执行"
        case .done: "已完成"
        case .error: "暂时出错了"
        }
    }
}

struct PlushMascot: View {
    var pose: PlushMascotPose
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    @State private var orbit = false
    @State private var blink = false
    @State private var clipFailed: Set<PlushMascotPose> = []
    @Environment(\.scenePhase) private var scenePhase

    init(pose: PlushMascotPose, size: CGFloat = 26) { self.pose = pose; self.size = size }
    init(state: CatpawPresenceState, size: CGFloat = 26) { self.init(pose: PlushMascotPose(state), size: size) }

    var body: some View {
        Group {
            if !reduceMotion, !clipFailed.contains(pose), let url = pose.clipURL {
                PlushMascotClip(url: url, playing: scenePhase == .active) { clipFailed.insert(pose) }
                    .frame(width: size * 1.15, height: size * 1.15)
                    .id(pose)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                staticPose
            }
        }
        .animation(.easeInOut(duration: 0.15), value: pose)
    }

    /// Static PNG + SwiftUI motion fallback (Reduce Motion → still; also used when no clip / playback fails).
    private var staticPose: some View {
        let animate = !reduceMotion
        return ZStack {
            Image(pose.assetName)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                // 等待: slow blink = brief vertical squash
                .scaleEffect(x: 1, y: blink ? 0.94 : 1, anchor: .bottom)
                .scaleEffect(scale(animate), anchor: .bottom)
                .rotationEffect(.degrees(rotation(animate)), anchor: .bottom)
                .offset(y: offsetY(animate))
                .opacity(pose == .error ? 0.72 : 1)
                .saturation(pose == .error ? 0.7 : 1)
                .transition(.opacity)
                .id(pose)

            if pose == .executing {
                Circle()
                    .fill(Color(UIColor(rgb: CatpawBrandTokens.primary)))
                    .frame(width: max(3, size * 0.14), height: max(3, size * 0.14))
                    .offset(y: -size * 0.58)
                    .rotationEffect(.degrees(animate && orbit ? 360 : 0))
                    .scaleEffect(x: 1, y: 0.35)   // flat ellipse orbit overhead
                    .offset(y: -size * 0.36)
            }
        }
        .frame(width: size * 1.15, height: size * 1.15)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pose)
        .onAppear { start() }
        .onChange(of: pose) { _, _ in start() }
        .accessibilityHidden(true)
    }

    private func scale(_ a: Bool) -> CGFloat {
        guard a else { return 1 }
        switch pose {
        case .idle: return phase ? 1.035 : 0.985   // breathing
        default: return 1
        }
    }
    private func rotation(_ a: Bool) -> Double {
        guard a else { return 0 }
        switch pose {
        case .thinking: return phase ? 7 : -7       // head tilt L/R
        case .writing: return phase ? 3 : 0         // slight lowered nod
        default: return 0
        }
    }
    private func offsetY(_ a: Bool) -> CGFloat {
        guard a else { return 0 }
        switch pose {
        case .writing: return phase ? size * 0.03 : 0
        case .done: return phase ? -size * 0.10 : 0  // light bounce
        case .executing: return phase ? -size * 0.02 : 0
        default: return 0
        }
    }

    private func start() {
        phase = false; orbit = false; blink = false
        guard !reduceMotion else { return }
        let loop: Animation
        switch pose {
        case .idle: loop = .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        case .thinking: loop = .spring(response: 0.9, dampingFraction: 0.7).repeatForever(autoreverses: true)
        case .writing: loop = .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
        case .executing: loop = .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
        case .done: loop = .spring(response: 0.3, dampingFraction: 0.45).repeatCount(2, autoreverses: true)
        case .error: return   // 暂停等待: still
        }
        withAnimation(loop) { phase = true }
        if pose == .executing {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { orbit = true }
        }
        if pose == .idle {
            withAnimation(.easeInOut(duration: 0.12).delay(2.6).repeatForever(autoreverses: true)) { blink = true }
        }
    }
}

/// First-open empty conversation backdrop: faint plush silhouette + sparse twinkling warm stars.
/// Decorative only; sits behind the hero text at ≤10% opacity so text contrast is unchanged.
struct PlushEmptyBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, d: Double)] = (0..<26).map { i in
        let f = Double(i)
        let x = (sin(f * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let y = (sin(f * 78.233) * 12345.6789).truncatingRemainder(dividingBy: 1)
        return (CGFloat(abs(x)), CGFloat(abs(y)), CGFloat(1 + (i % 3)) * 0.9, 2.4 + Double(i % 5) * 0.7)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { ctx in
                    let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                    Canvas { g, size in
                        for (i, s) in Self.stars.enumerated() {
                            let tw = reduceMotion ? 0.6 : 0.5 + 0.5 * sin(t / s.d * .pi * 2 + Double(i))
                            let rect = CGRect(x: s.x * size.width, y: s.y * size.height, width: s.r * 2, height: s.r * 2)
                            let tint = i % 3 == 0 ? CatpawBrandTokens.primary : CatpawBrandTokens.clayShadow
                            g.fill(Path(ellipseIn: rect), with: .color(Color(UIColor(rgb: tint)).opacity(0.08 + 0.14 * tw)))
                        }
                    }
                }
                Image("MascotFront")
                    .resizable().scaledToFit()
                    .frame(width: min(geo.size.width * 0.78, 340))
                    .opacity(0.08)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    .position(x: geo.size.width * 0.62, y: geo.size.height * 0.48)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Muted, looping, transparent mascot clip. Pauses offscreen / when the scene is not active.
private struct PlushMascotClip: UIViewRepresentable {
    let url: URL
    var playing: Bool
    var onFail: () -> Void

    func makeUIView(context: Context) -> ClipView { ClipView(url: url, onFail: onFail) }
    func updateUIView(_ v: ClipView, context: Context) { v.setPlaying(playing) }
    static func dismantleUIView(_ v: ClipView, coordinator: ()) { v.teardown() }

    final class ClipView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var statusObs: NSKeyValueObservation?
        private var wantsPlay = true

        init(url: URL, onFail: @escaping () -> Void) {
            super.init(frame: .zero)
            backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
            playerLayer.backgroundColor = UIColor.clear.cgColor
            playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            playerLayer.videoGravity = .resizeAspect
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            statusObs = looper?.observe(\.status) { l, _ in
                if l.status == .failed { DispatchQueue.main.async { onFail() } }
            }
            playerLayer.player = player
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        func setPlaying(_ on: Bool) { wantsPlay = on; apply() }
        private func apply() { if wantsPlay && window != nil { player.play() } else { player.pause() } }
        func teardown() { player.pause(); statusObs = nil; looper?.disableLooping(); looper = nil; playerLayer.player = nil }
    }
}
