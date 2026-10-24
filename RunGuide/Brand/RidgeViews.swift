import SwiftUI

/// The five monument ridges stacked with the opacity recipe.
/// `spread` 0 draws them as on the artboard; positive values squeeze the back layers down behind
/// the front ones, negative values fan them up. Nothing is ever stretched.
struct RidgeStack: View {
    var spread: CGFloat
    /// Drawing width – wider than the screen, so spreading never shows an edge.
    var width: CGFloat
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
                .foregroundStyle(tint.color)
                // Flatten each layer before fading it, so its own base doesn't double up.
                .compositingGroup()
                .opacity(tint.opacity)
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

    private var scale: CGFloat { width / 3000 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            part("LockupMonument")
                .foregroundStyle(Brand.wordmark)
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

/// A shape filled with a medal texture – for PR and best-effort moments.
struct MedalFill<S: Shape>: View {
    var medal: Brand.Medal
    var shape: S

    var body: some View {
        Image(medal.texture)
            .resizable()
            .scaledToFill()
            .clipShape(shape)
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
