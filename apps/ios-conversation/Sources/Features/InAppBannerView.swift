import SwiftUI

// V4 (wave2 plan): in-app floating capsule notification. Demo-grade.
// Usage: attach `.catpawInAppBanner(center)` near the root; call `center.show(...)` from the foreground
// UNUserNotificationCenter delegate or proactive-event poller (wiring belongs to M2 on the Mac side).

struct catInAppBanner: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var body: String
    var symbol: String = "pawprint.fill"
    var deepLink: URL?
}

@MainActor @Observable final class catInAppBannerCenter {
    static let shared = catInAppBannerCenter()
    private(set) var current: catInAppBanner?
    private var queue: [catInAppBanner] = []
    private var dismissTask: Task<Void, Never>?
    var duration: Duration = .seconds(4)
    /// Tap handler; default opens `deepLink` through the app's URL handling.
    var onTap: ((catInAppBanner) -> Void)?

    func show(_ banner: catInAppBanner) {
        if current == nil { present(banner) } else { queue.append(banner) }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
        if !queue.isEmpty {
            let next = queue.removeFirst()
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); self.present(next) }
        }
    }

    func tap() {
        guard let banner = current else { return }
        onTap?(banner)
        dismiss()
    }

    private func present(_ banner: catInAppBanner) {
        current = banner
        dismissTask?.cancel()
        let d = duration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled, self?.current?.id == banner.id else { return }
            self?.dismiss()
        }
    }
}

@MainActor struct InAppBannerView: View {
    let banner: catInAppBanner
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.symbol)
                .foregroundStyle(catColors.onInk)
                .frame(width: 32, height: 32)
                .background(catBrand.paw, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(catTypography.Role.secondary.font.weight(.semibold)).foregroundStyle(catColors.ink).lineLimit(1)
                if !banner.body.isEmpty {
                    Text(banner.body).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("inapp.banner")
    }
}

private struct InAppBannerOverlay: ViewModifier {
    @Bindable var center: catInAppBannerCenter
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner = center.current {
                InAppBannerView(banner: banner)
                    .padding(.horizontal, 12).padding(.top, 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        if center.onTap == nil, let url = banner.deepLink { openURL(url) }
                        center.tap()
                    }
                    .gesture(DragGesture(minimumDistance: 10).onEnded { v in if v.translation.height < -10 { center.dismiss() } })
                    .id(banner.id)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: center.current?.id)
    }
}

extension View {
    func catpawInAppBanner(_ center: catInAppBannerCenter = .shared) -> some View { modifier(InAppBannerOverlay(center: center)) }
}
