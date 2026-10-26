import SwiftUI
import UIKit
import RunGuideCore

/// The five monument ridges stacked with the opacity recipe.
/// `spread` 0 draws them as on the artboard; positive values squeeze the back layers down behind
/// the front ones, negative values fan them up. Nothing is ever stretched.
struct RidgeStack: View {
    var spread: CGFloat
    /// Drawing width – wider than the screen, so spreading never shows an edge.
    var width: CGFloat
    /// Per-layer colour and opacity, back to front. Nil uses the header recipe (one tint, 15%).
    var fills: [(Color, Double)]? = nil
    @Environment(\.colorScheme) private var scheme

    /// Solid fill under each ridge, so a lifted layer never shows a gap.
    private let base: CGFloat = 900

    var body: some View {
        let scale = width / Brand.ridgeArtboard.width
        let vertical = scale * Brand.ridgeSquash
        let tint = Brand.ridgeTint(scheme)
        ZStack(alignment: .bottom) {
            ForEach(Array(Brand.ridges.enumerated()), id: \.offset) { index, name in
                VStack(spacing: 0) {
                    Image(name)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: width, height: Brand.ridgeArtboard.height * vertical)
                    Rectangle()
                        .frame(width: width, height: base)
                }
                .foregroundStyle(fills?[index].0 ?? tint.color)
                // Flatten each layer before fading it, so its own base doesn't double up.
                .compositingGroup()
                .opacity(fills?[index].1 ?? tint.opacity)
                .offset(y: base + Brand.Header.stackDrop + Brand.ridgeLift[index] * vertical * spread)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

/// Sky plus ridges, filling its frame and anchored to the bottom edge.
struct RidgeBackdrop: View {
    var spread: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Brand.sky
                RidgeStack(spread: spread, width: geo.size.width * Brand.Header.bleed)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
        .clipped()
    }
}

/// The MONUMENT wordmark on its own (the header version).
struct Wordmark: View {
    var body: some View {
        Image("Wordmark")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(3000 / 300, contentMode: .fit)
            .foregroundStyle(Brand.wordmark)
            .accessibilityLabel("Monument")
    }
}

/// The full MONUMENT ALMANAC lockup, built from its separately coloured parts so the launch
/// animation can move them independently. All parts share the 3000 × 410 artboard.
struct Lockup: View {
    var width: CGFloat
    /// 0 = in place; 1 = ALMANAC and the bars have dropped away.
    var drop: CGFloat = 0
    /// 0 = lockup MONUMENT (with the extended M and T); 1 = standalone wordmark.
    var crossfade: CGFloat = 0
    var medal: Brand.Medal = .gold
    /// MONUMENT's colour: the wordmark colour normally, white on the forest footer.
    var monumentColor: Color = Brand.wordmark

    private var scale: CGFloat { width / 3000 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            part("LockupMonument")
                .foregroundStyle(monumentColor)
                .opacity(1 - crossfade)
            Wordmark()
                .frame(width: width)
                .opacity(crossfade)

            Group {
                part("LockupAlmanac").foregroundStyle(Brand.sage)
                bar("LockupBarLeft", x: 1481)
                bar("LockupBarRight", x: 2665)
            }
            .offset(y: drop * 80)
            .opacity(1 - drop)
        }
        .frame(width: width, height: 410 * scale, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monument Almanac")
    }

    private func part(_ name: String) -> some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .frame(width: width, height: 410 * scale)
    }

    /// The bar's texture, sized to the bar itself so its gradient runs top to bottom like the artwork.
    private func bar(_ name: String, x: CGFloat) -> some View {
        Image(medal.texture)
            .resizable()
            .scaledToFill()
            .frame(width: 127 * scale, height: 110 * scale)
            .clipped()
            .offset(x: x * scale, y: 282 * scale)
            .frame(width: width, height: 410 * scale, alignment: .topLeading)
            .mask(part(name))
    }
}

/// A shape filled with a medal texture – for PR and best-effort moments. Sizes to its frame.
struct MedalFill<S: Shape>: View {
    var medal: Brand.Medal
    var shape: S

    var body: some View {
        shape
            .fill(medal.flat)
            .overlay {
                Image(medal.texture)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(shape)
    }
}

/// A best-effort medal. This year's top three: the logotype's slanted bar in gold, silver or
/// bronze. All-time top three: inverted – a solid metal badge with the bar cut out of it.
struct MedalBadge: View {
    let medal: EffortMedal

    private var metal: Brand.Medal { Brand.Medal(rawValue: medal.place) ?? .bronze }

    var body: some View {
        Group {
            if medal.period == .allTime {
                MedalFill(medal: metal, shape: RoundedRectangle(cornerRadius: 3))
                    .frame(width: 20, height: 13)
                    .mask {
                        ZStack {
                            Rectangle()
                            SlantBar()
                                .frame(width: 10, height: 5)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
            } else {
                MedalFill(medal: metal, shape: SlantBar())
                    .frame(width: 14, height: 6)
            }
        }
        .accessibilityLabel(medal.description)
    }
}

/// The slanted bar from the logotype, as a shape (used for the tab indicator and medal tags).
struct SlantBar: Shape {
    var slant: CGFloat = 0.27

    func path(in rect: CGRect) -> Path {
        let lean = rect.height * slant
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + lean, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - lean, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}


/// A page title in Akira, slanted like the logotype, in place of the wordmark.
struct AkiraTitle: View {
    let text: String
    var size: CGFloat = 26

    var body: some View {
        Text(text.uppercased())
            .font(.hero(size, relativeTo: .title2))
            .akiraSlant()
            .foregroundStyle(Brand.wordmark)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The foot of a page: the ridges darkening into forest to meet the tab bar, with the
/// MONUMENT ALMANAC lockup. Pulling up past the end spreads the ridges, like the header.
struct RidgeFooter: View {
    /// How far the page has been pulled up past its end.
    var pull: CGFloat = 0
    var loading = false

    static let height: CGFloat = 190
    static let band: CGFloat = 62
    /// Back to front: forest, darkening to solid.
    static let fills: [(Color, Double)] = [(Brand.forest, 0.12), (Brand.forest, 0.2), (Brand.forest, 0.32),
                                           (Brand.forest, 0.55), (Brand.forest, 1)]

    var body: some View {
        let spread = loading ? -0.6 : Brand.Header.restSpread - min(pull, 120) / 120 * 1.2
        VStack(spacing: 0) {
            GeometryReader { geo in
                RidgeStack(spread: spread, width: geo.size.width * Brand.Header.bleed, fills: Self.fills)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
            .clipped()
            ZStack {
                Brand.forest
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Lockup(width: 196, monumentColor: .white)
                }
            }
            .frame(height: Self.band)
        }
        .frame(height: Self.height)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: loading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monument Almanac")
    }
}

/// Fires once each time the page is pulled up past its end, then re-arms when it settles.
final class PullUpLoader: ObservableObject {
    @Published private(set) var loading = false
    private var armed = true
    static let threshold: CGFloat = 70

    func update(overscroll: CGFloat, action: (() async -> Void)?) {
        if overscroll < 8 { armed = true }
        guard let action, overscroll > Self.threshold, armed, !loading else { return }
        armed = false
        loading = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            await action()
            self.loading = false
        }
    }
}
