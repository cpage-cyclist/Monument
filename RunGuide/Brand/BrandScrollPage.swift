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
    @Environment(\.tabPager) private var pager
    /// Whether the current drag has been claimed as a sideways swipe between tabs.
    @State private var swipe: Bool?

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
            let visibleBottom = outer.size.height + outer.safeAreaInsets.top
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PullRidgeHeader(topInset: outer.safeAreaInsets.top, title: pageTitle,
                                    refreshing: puller.refreshing, confirmed: puller.confirmed) {
                        accessory
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        title
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .padding(.top, 14)
                    // Rises in with the ridges at launch, scrolling up at the same pace as the title.
                    .offset(y: launch.revealed ? 0 : launch.rise)

                    if showsFooter {
                        Spacer(minLength: 0)
                        RidgeFooter(pull: overscroll, loading: loader.loading)
                    }
                }
                // Short pages still put the footer at the foot of the screen.
                .frame(minHeight: visibleBottom, alignment: .top)
                // Forest carries on below the footer, so bouncing past the end never shows the page
                // colour beneath the tab-bar green.
                .background(alignment: .bottom) {
                    if showsFooter {
                        Brand.forest.frame(height: 1200).offset(y: 1200)
                    }
                }
                // One reader on the whole column (always on screen) drives both the header and the
                // footer, so the collapsed ridge bar keeps tracking once the header has scrolled away.
                .background {
                    GeometryReader { g in
                        let frame = g.frame(in: .named(BrandScroll.space))
                        Color.clear.preference(key: ScrollFrameKey.self,
                                               value: ScrollFrame(top: frame.minY, bottom: frame.maxY))
                    }
                }
            }
            .coordinateSpace(name: BrandScroll.space)
            .ignoresSafeArea(edges: .top)
            .onPreferenceChange(ScrollFrameKey.self) { frame in
                headerOffset = frame.top
                puller.update(offset: frame.top) { await onRefresh() }
                // The column's bottom rising above the visible bottom edge is the pull-up.
                overscroll = showsFooter ? max(0, visibleBottom - frame.bottom) : 0
                loader.update(overscroll: overscroll, action: onLoadMore)
            }
            // Sideways drags swipe between tabs; anything mostly vertical is left to the scroll view.
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { v in
                        let dx = v.translation.width, dy = v.translation.height
                        if swipe == nil { swipe = pager?.blocked != true && abs(dx) > abs(dy) * 1.6 }
                        if swipe == true { pager?.changed(dx) }
                    }
                    .onEnded { v in
                        if swipe == true {
                            pager?.ended(v.translation.width, v.predictedEndTranslation.width, outer.size.width)
                        }
                        swipe = nil
                        pager?.blocked = false
                    }
            )
            .overlay(alignment: .top) {
                CollapsedRidgeBar(topInset: outer.safeAreaInsets.top, offset: headerOffset, title: pageTitle)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .background(Brand.page)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Where the page's column sits in its scroll view: top (positive when pulled down) and bottom.
struct ScrollFrame: Equatable {
    var top: CGFloat
    var bottom: CGFloat
}

struct ScrollFrameKey: PreferenceKey {
    static var defaultValue = ScrollFrame(top: 0, bottom: 0)
    static func reduce(value: inout ScrollFrame, nextValue: () -> ScrollFrame) { value = nextValue() }
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
            .background { RidgePageBackground() }
    }

    /// A sheet's header: the same ridges, with a short Akira title in the middle so the sheet's
    /// Cancel and Done keep their places.
    func ridgeSheetHeader(_ title: String) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AkiraTitle(text: title, size: 15)
                }
            }
            .background { RidgePageBackground() }
    }
}

/// The page colour with a strip of ridges behind the navigation bar.
struct RidgePageBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Brand.page.ignoresSafeArea()
            RidgeBackdrop(spread: Brand.Header.restSpread)
                .frame(height: 56)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// A List or Form in Monument style: the page shows through, rows are white (forest in dark
/// mode) in square bands, section titles are small caps labels. Content is clipped below the
/// navigation bar so it doesn't scroll over the ridges.
struct BrandList<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List {
            Group { content }
                .listRowBackground(Brand.sky)
                .listRowSeparatorTint(Brand.hairline.opacity(0.25))
        }
        .listStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Brand.accent)
        .clipped()
    }
}

typealias BrandForm<Content: View> = BrandList<Content>

/// A list section with a Monument label for its title.
struct BrandSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            CardLabel(text: title).foregroundStyle(Brand.wordmark)
        }
    }
}
