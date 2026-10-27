import SwiftUI

/// Whether the launch animation has handed over to the app. Today's content and the tab bar
/// rise into place as it flips.
final class LaunchState: ObservableObject {
    @Published var revealed = false
    /// How far the first page travels as it scrolls up into place at launch: a full screen, so
    /// the title and content come up from below the bottom edge.
    @Published var rise: CGFloat = 900
}

enum AppTab: CaseIterable, Hashable {
    case today, calendar, activities, record, rider

    var title: String {
        switch self {
        case .today: "Today"
        case .calendar: "Calendar"
        case .activities: "Activities"
        case .record: "Record"
        case .rider: "Rider"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .activities: "chart.xyaxis.line"
        case .record: "record.circle"
        case .rider: "person.crop.square"
        }
    }
}

/// Forest green tab bar with white icons; the selected tab is full white, the rest dimmed.
struct BrandTabBar: View {
    let selection: AppTab
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: selected ? .semibold : .regular))
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.custom(selected ? Brand.Face.bold : Brand.Face.medium, size: 10))
                    }
                    .foregroundStyle(Color.white.opacity(selected ? 1 : 0.6))
                    .frame(maxWidth: .infinity, minHeight: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.top, 8)
        .background(Brand.forest.ignoresSafeArea(edges: .bottom))
    }
}

/// Lets a page switch tabs (the Rider launch pad).
private struct SwitchTabKey: EnvironmentKey {
    static let defaultValue: (AppTab) -> Void = { _ in }
}

extension EnvironmentValues {
    var switchTab: (AppTab) -> Void {
        get { self[SwitchTabKey.self] }
        set { self[SwitchTabKey.self] = newValue }
    }
}

/// Swiping sideways between tabs. The root owns it and lays the pages out from `drag`; each
/// top-level page (`BrandScrollPage`) feeds it its horizontal drags. Passed as a plain environment
/// value rather than an observed object, so a drag only redraws the root, not every page.
final class TabPager: ObservableObject {
    /// How far the current page is dragged sideways (negative = towards the next tab).
    @Published var drag: CGFloat = 0
    /// The neighbouring tab peeking in during a drag.
    @Published var peek: AppTab?

    /// Set while a touch is on something that drags sideways itself (a scrubbable chart).
    var blocked = false

    var changed: (CGFloat) -> Void = { _ in }
    var ended: (_ translation: CGFloat, _ predicted: CGFloat, _ width: CGFloat) -> Void = { _, _, _ in }
}

private struct TabPagerKey: EnvironmentKey {
    static let defaultValue: TabPager? = nil
}

extension EnvironmentValues {
    var tabPager: TabPager? {
        get { self[TabPagerKey.self] }
        set { self[TabPagerKey.self] = newValue }
    }
}

extension View {
    /// For views that use sideways drags themselves, like a scrubbable chart: a drag that starts
    /// here never swipes to another tab.
    func blocksTabSwipe() -> some View { modifier(BlocksTabSwipe()) }
}

private struct BlocksTabSwipe: ViewModifier {
    @Environment(\.tabPager) private var pager

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pager?.blocked = true }
                .onEnded { _ in pager?.blocked = false }
        )
    }
}
