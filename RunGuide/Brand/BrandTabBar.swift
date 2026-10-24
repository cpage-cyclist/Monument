import SwiftUI

/// Whether the launch animation has handed over to the app. Today's content and the tab bar
/// rise into place as it flips.
final class LaunchState: ObservableObject {
    @Published var revealed = false
}

enum AppTab: CaseIterable, Hashable {
    case today, week, activities, run

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .activities: "Activities"
        case .run: "Run"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .week: "calendar"
        case .activities: "chart.xyaxis.line"
        case .run: "figure.run"
        }
    }
}

/// Forest green tab bar with white icons; the selected tab gets the logotype's gold slant.
struct BrandTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        MedalFill(medal: .gold, shape: SlantBar())
                            .frame(width: 22, height: 4)
                            .opacity(selected ? 1 : 0)
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
        .padding(.top, 6)
        .background(Brand.forest.ignoresSafeArea(edges: .bottom))
    }
}
