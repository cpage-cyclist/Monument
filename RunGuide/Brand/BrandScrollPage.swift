import SwiftUI

/// A top-level page in the Monument style: ridge header (pull to refresh, collapsing ridge strip
/// on scroll), a title row, then the content, all on the sage page colour.
struct BrandScrollPage<Title: View, Accessory: View, Content: View>: View {
    private let onRefresh: () async -> Void
    private let title: Title
    private let accessory: Accessory
    private let content: Content

    @StateObject private var puller = PullToRefresh()
    @State private var headerOffset: CGFloat = 0
    @EnvironmentObject private var launch: LaunchState

    init(onRefresh: @escaping () async -> Void,
         @ViewBuilder title: () -> Title,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.onRefresh = onRefresh
        self.title = title()
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PullRidgeHeader(topInset: outer.safeAreaInsets.top, refreshing: puller.refreshing) {
                        accessory
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        title
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .padding(.top, 2)
                    // Rises in with the ridges at launch.
                    .offset(y: launch.revealed ? 0 : 420)
                }
            }
            .coordinateSpace(name: BrandScroll.space)
            .ignoresSafeArea(edges: .top)
            .onPreferenceChange(HeaderOffsetKey.self) { offset in
                headerOffset = offset
                puller.update(offset: offset) { await onRefresh() }
            }
            .overlay(alignment: .top) {
                CollapsedRidgeBar(topInset: outer.safeAreaInsets.top, offset: headerOffset)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .background(Brand.page)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Large bold page title in Helvetica Neue.
struct PageTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.brand(.largeTitle, weight: .bold))
    }
}

/// Gear button for the header's top-right corner.
struct HeaderButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Brand.wordmark)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

/// A thin rule between rows inside a card.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Brand.hairline.opacity(0.3)).frame(height: 0.5)
    }
}

/// Section heading above a card, e.g. a day.
struct SectionTitle: View {
    let text: String
    var emphasised = false
    var body: some View {
        Text(text)
            .font(.brand(.headline, weight: emphasised ? .bold : .medium))
            .foregroundStyle(emphasised ? Color.primary : Color.primary.opacity(0.75))
    }
}

extension View {
    /// Brand page colour behind a pushed screen (detail views).
    func brandPageBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Brand.page)
    }
}
