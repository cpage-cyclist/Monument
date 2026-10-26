import SwiftUI

/// A top-level page in the Monument style: ridge header with the page's name in Akira (pull to
/// refresh, collapsing ridge strip on scroll), an optional row under it, the content, and the ridge
/// footer meeting the tab bar (pull up to load more, where the page has more to load).
struct BrandScrollPage<Title: View, Accessory: View, Content: View>: View {
    private let pageTitle: String
    private let onRefresh: () async -> Void
    private let onLoadMore: (() async -> Void)?
    private let showsFooter: Bool
    private let title: Title
    private let accessory: Accessory
    private let content: Content

    @StateObject private var puller = PullToRefresh()
    @StateObject private var loader = PullUpLoader()
    @State private var headerOffset: CGFloat = 0
    @State private var overscroll: CGFloat = 0
    @EnvironmentObject private var launch: LaunchState

    init(_ pageTitle: String,
         onRefresh: @escaping () async -> Void,
         onLoadMore: (() async -> Void)? = nil,
         showsFooter: Bool = true,
         @ViewBuilder title: () -> Title,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.pageTitle = pageTitle
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.showsFooter = showsFooter
        self.title = title()
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PullRidgeHeader(topInset: outer.safeAreaInsets.top, title: pageTitle,
                                    refreshing: puller.refreshing) {
                        accessory
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        title
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .padding(.top, 14)
                    // Rises in with the ridges at launch.
                    .offset(y: launch.revealed ? 0 : 420)

                    if showsFooter {
                        Spacer(minLength: 0)
                        RidgeFooter(pull: overscroll, loading: loader.loading)
                            .background {
                                GeometryReader { g in
                                    Color.clear.preference(key: FooterBottomKey.self,
                                                           value: g.frame(in: .named(BrandScroll.space)).maxY)
                                }
                            }
                    }
                }
                // Short pages still put the footer at the foot of the screen.
                .frame(minHeight: outer.size.height + outer.safeAreaInsets.top, alignment: .top)
            }
            .coordinateSpace(name: BrandScroll.space)
            .ignoresSafeArea(edges: .top)
            .onPreferenceChange(HeaderOffsetKey.self) { offset in
                headerOffset = offset
                puller.update(offset: offset) { await onRefresh() }
            }
            .onPreferenceChange(FooterBottomKey.self) { bottom in
                // The footer's bottom rising above the visible bottom edge is the pull-up.
                let visibleBottom = outer.size.height + outer.safeAreaInsets.top
                overscroll = max(0, visibleBottom - bottom)
                loader.update(overscroll: overscroll, action: onLoadMore)
            }
            .overlay(alignment: .top) {
                CollapsedRidgeBar(topInset: outer.safeAreaInsets.top, offset: headerOffset, title: pageTitle)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .background(Brand.page)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Large bold heading in Plex, for sheets and pushed screens without a ridge header.
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


extension View {
    /// A pushed screen's header: the ridges behind a see-through navigation bar, the system back
    /// chevron, and a short title in Akira (a sport and date, never a user-written name).
    func ridgeNavHeader(_ title: String) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AkiraTitle(text: title, size: 18)
                }
            }
            .background(alignment: .top) {
                RidgeBackdrop(spread: Brand.Header.restSpread)
                    .frame(height: 56)
                    .ignoresSafeArea(edges: .top)
            }
    }
}
