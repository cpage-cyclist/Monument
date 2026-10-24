import SwiftUI
import UIKit

/// Coordinate space for a ScrollView that has a `PullRidgeHeader` at its top.
enum BrandScroll {
    static let space = "brandScroll"
}

/// How far the header's top has moved in the scroll view (positive = pulled down, negative = scrolled up).
struct HeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The ridge header: wordmark over the monuments. Pull the page down and the ridges fan apart
/// (without stretching); past the threshold it triggers a refresh, and the layers stay parted
/// until the refresh finishes.
///
/// Place it first inside a ScrollView that has `.coordinateSpace(name: BrandScroll.space)` and
/// ignores the top safe area. Read the offset with `.onPreferenceChange(HeaderOffsetKey.self)`.
struct PullRidgeHeader<Accessory: View>: View {
    let topInset: CGFloat
    var refreshing: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let rest = topInset + Brand.Header.body
        GeometryReader { geo in
            let minY = geo.frame(in: .named(BrandScroll.space)).minY
            let pull = max(0, minY)
            let pulled = Brand.Header.spread(forPull: pull)
            let spread = refreshing ? min(pulled, Brand.Header.restSpread * 0.2) : pulled
            ZStack(alignment: .topLeading) {
                RidgeBackdrop(spread: spread)
                Wordmark()
                    .frame(width: Brand.Header.wordmarkWidth)
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
            .preference(key: HeaderOffsetKey.self, value: minY)
        }
        .frame(height: rest)
    }
}

/// A thin strip of ridges pinned to the top once the full header has scrolled away.
struct CollapsedRidgeBar: View {
    let topInset: CGFloat
    /// The header's scroll offset (negative when scrolled up).
    let offset: CGFloat

    var body: some View {
        let start = Brand.Header.body - 40
        let progress = min(max((-offset - start) / 30, 0), 1)
        RidgeBackdrop(spread: 1.0)
            .frame(height: topInset + 30)
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
    private var armed = true

    func update(offset: CGFloat, action: @escaping () async -> Void) {
        if offset < 8 { armed = true }
        guard offset > Brand.Header.refreshPull, armed, !refreshing else { return }
        armed = false
        refreshing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            await action()
            self.refreshing = false
        }
    }
}
