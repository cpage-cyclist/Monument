import SwiftUI
import UIKit

/// Coordinate space for a ScrollView that has a `PullRidgeHeader` at its top.
enum BrandScroll {
    static let space = "brandScroll"
}

/// The ridge header: wordmark over the monuments. Pull the page down and the ridges fan apart
/// (without stretching); past the threshold it triggers a refresh, and the layers stay parted
/// until the refresh finishes.
///
/// Place it first inside a ScrollView that has `.coordinateSpace(name: BrandScroll.space)` and
/// ignores the top safe area (`BrandScrollPage` does this and tracks the scroll position).
struct PullRidgeHeader<Accessory: View>: View {
    let topInset: CGFloat
    /// The page's name in Akira; nil shows the MONUMENT wordmark.
    var title: String? = nil
    var refreshing: Bool
    /// Briefly true once a refresh lands: the gold bar slides in after the title.
    var confirmed: Bool = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let rest = topInset + Brand.Header.body
        GeometryReader { geo in
            let minY = geo.frame(in: .named(BrandScroll.space)).minY
            let pull = max(0, minY)
            let pulled = Brand.Header.spread(forPull: pull)
            let spread = refreshing ? min(pulled, Brand.Header.refreshingSpread) : pulled
            ZStack(alignment: .topLeading) {
                RidgeBackdrop(spread: spread)
                Group {
                    if let title {
                        HStack(alignment: .center, spacing: 12) {
                            AkiraTitle(text: title)
                            if confirmed {
                                SuccessBar()
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: geo.size.width - 90, alignment: .leading)
                        .animation(.snappy(duration: 0.35), value: confirmed)
                    } else {
                        Wordmark().frame(width: Brand.Header.wordmarkWidth)
                    }
                }
                .padding(.leading, Brand.Header.wordmarkInset.x)
                .padding(.top, topInset + Brand.Header.wordmarkInset.y)
                HStack {
                    Spacer()
                    accessory
                }
                .padding(.trailing, 12)
                .padding(.top, topInset + 4)
            }
            .frame(width: geo.size.width, height: rest + pull)
            .offset(y: -pull)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: refreshing)
        }
        .frame(height: rest)
    }
}

/// A thin strip of ridges pinned to the top once the full header has scrolled away.
struct CollapsedRidgeBar: View {
    let topInset: CGFloat
    /// The header's scroll offset (negative when scrolled up).
    let offset: CGFloat
    var title: String? = nil

    var body: some View {
        let start = Brand.Header.body - 40
        let progress = min(max((-offset - start) / 30, 0), 1)
        RidgeBackdrop(spread: 1.0)
            .frame(height: topInset + 30)
            .overlay(alignment: .bottomLeading) {
                if let title {
                    AkiraTitle(text: title, size: 13)
                        .padding(.leading, 20)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Brand.hairline).frame(height: 0.5)
            }
            .opacity(progress)
            .allowsHitTesting(false)
    }
}

/// Fires once each time a pull passes the threshold, then re-arms when the page settles.
final class PullToRefresh: ObservableObject {
    @Published private(set) var refreshing = false
    /// Shows the success bar for a moment after a refresh lands.
    @Published private(set) var confirmed = false
    private var armed = true
    private static let minimumHold: TimeInterval = 0.7

    func update(offset: CGFloat, action: @escaping () async -> Void) {
        if offset < 8 { armed = true }
        guard offset > Brand.Header.refreshPull, armed, !refreshing else { return }
        armed = false
        refreshing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            // Hold the ridges parted for a beat even when the answer comes back at once, so a
            // refresh always reads as one.
            let started = Date()
            await action()
            let held = Date().timeIntervalSince(started)
            if held < Self.minimumHold {
                try? await Task.sleep(nanoseconds: UInt64((Self.minimumHold - held) * 1_000_000_000))
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.refreshing = false
            self.confirmed = true
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            self.confirmed = false
        }
    }
}
