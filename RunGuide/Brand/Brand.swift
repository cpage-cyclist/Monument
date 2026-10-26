import SwiftUI
import UIKit

/// Monument Almanac's look: colours, type and the ridge recipe. Everything visual reads from here.
enum Brand {

    // MARK: Colours

    /// #00321F – the primary brand colour.
    static let forest = Color(red: 0, green: 50 / 255, blue: 31 / 255)
    /// #7F9990 – the secondary green, also the ridge tint in light mode.
    static let sage = Color(red: 127 / 255, green: 153 / 255, blue: 144 / 255)

    /// Words of the logo: forest green on light, white on dark.
    static let wordmark = Color(light: UIColor(red: 0, green: 50 / 255, blue: 31 / 255, alpha: 1), dark: .white)
    /// Accent for controls: forest green on light, sage on dark (forest is too dark on black).
    static let accent = Color(light: UIColor(red: 0, green: 50 / 255, blue: 31 / 255, alpha: 1),
                              dark: UIColor(red: 160 / 255, green: 186 / 255, blue: 176 / 255, alpha: 1))
    /// Sky behind the ridges: white on light, forest green on dark.
    static let sky = Color(light: .white, dark: UIColor(red: 0, green: 50 / 255, blue: 31 / 255, alpha: 1))
    /// The page: the colour of all five ridges overlapping, so the header flows straight into it.
    /// Light: #B8C6C1 (five 15% light-green layers on white). Dark: #68867B (five 10% white layers on forest).
    static let page = Color(light: UIColor(red: 184 / 255, green: 198 / 255, blue: 193 / 255, alpha: 1),
                            dark: UIColor(red: 104 / 255, green: 134 / 255, blue: 123 / 255, alpha: 1))
    /// Crisp Standert-style rules.
    /// Warnings, errors and Strava: bronze rather than stock red or orange.
    static let alert = Color(red: 169 / 255, green: 96 / 255, blue: 52 / 255)
    static let hairline = Color(light: UIColor(white: 0.07, alpha: 1), dark: UIColor(white: 1, alpha: 0.55))

    // MARK: Ridges

    /// The five monuments, back to front. Each SVG is a single shape on the same 3000 × 2200 artboard.
    static let ridges = ["RidgeLombardia", "RidgeSanremo", "RidgeLiege", "RidgeFlanders", "RidgeRoubaix"]
    static let ridgeArtboard = CGSize(width: 3000, height: 2200)
    /// How far each ridge's top sits above Roubaix's, in artboard units. Used to compact or spread the stack.
    static let ridgeLift: [CGFloat] = [1634, 1138, 665, 288, 0]
    /// Vertical squash of the profiles (like reducing an elevation chart's vertical exaggeration).
    static let ridgeSquash: CGFloat = 0.4

    /// The stacking recipe: every layer the same tint at the same opacity, so overlaps read darker.
    /// Light: light green at 15% on white. Dark: white at 10% on forest green.
    static func ridgeTint(_ scheme: ColorScheme) -> (color: Color, opacity: Double) {
        scheme == .dark ? (.white, 0.10) : (sage, 0.15)
    }

    // MARK: Header geometry (shared by the Today header and the launch animation so they line up)

    enum Header {
        /// Header height below the status bar at rest.
        static let body: CGFloat = 84
        /// Ridge compaction at rest (0 = as drawn, positive = squeezed, negative = spread).
        static let restSpread: CGFloat = 0.12
        /// Full spread at the end of a pull, and on the launch screen.
        static let pulledSpread: CGFloat = -1.5
        static let launchSpread: CGFloat = -3.0
        /// The stack sits this far below its natural position, trimming Roubaix's flat base.
        static let stackDrop: CGFloat = 14
        /// Pull distance that triggers a refresh.
        static let refreshPull: CGFloat = 110
        static let maxPull: CGFloat = 160
        /// The ridges are drawn wider than the screen so a spread never shows an edge.
        static let bleed: CGFloat = 1.18
        /// Wordmark at rest: top-leading, below the status bar.
        static let wordmarkWidth: CGFloat = 200
        static let wordmarkInset = CGPoint(x: 20, y: 14)

        static func spread(forPull pull: CGFloat) -> CGFloat {
            let t = min(max(pull, 0), maxPull) / maxPull
            return restSpread + (pulledSpread - restSpread) * t
        }
    }

    // MARK: Data colours

    /// Series colours for charts, all from the brand itself: forest, sage, the hairline and the
    /// three medal metals. They're deliberately muted, so shape does part of the work: W′bal and
    /// altitude are shaded areas, speed/pace is dashed, power, HR and cadence are solid lines, and
    /// every series is named in the chips and readout. Charts always draw on white.
    enum Data {
        static let surface = Color.white
        /// Axis labels and grid on the white surface.
        static let ink = Color(hex: 0x1A1F1C)
        static let power = Color(hex: 0x00321F)       // forest
        static let wbal = Color(hex: 0x7F9990)        // sage, as an area
        static let heartRate = Color(hex: 0xAA954B)   // gold
        static let cadence = Color(hex: 0xA96034)     // bronze
        static let speed = Color(hex: 0xA0978A)       // silver, dashed
        static let altitude = Color(hex: 0x121212)    // hairline, as a faint area
        // Fitness, fatigue and form, on the Calendar chart and Today alike.
        static let fitness = Color(hex: 0x00321F)     // forest
        static let fatigue = Color(hex: 0xA96034)     // bronze
        static let form = Color(hex: 0xAA954B)        // gold
    }

    // MARK: Medals (gold / silver / bronze for top efforts)

    enum Medal: Int, CaseIterable {
        case gold = 1, silver, bronze

        var texture: String {
            switch self {
            case .gold: "TextureGold"
            case .silver: "TextureSilver"
            case .bronze: "TextureBronze"
            }
        }

        /// Flat mid-tone for small accents where the texture would be lost.
        var flat: Color {
            switch self {
            case .gold: Color(red: 170 / 255, green: 149 / 255, blue: 75 / 255)   // #AA954B
            case .silver: Color(red: 160 / 255, green: 151 / 255, blue: 138 / 255) // #A0978A
            case .bronze: Color(red: 169 / 255, green: 96 / 255, blue: 52 / 255)   // #A96034
            }
        }
    }

    // MARK: Type

    /// IBM Plex Sans for text, IBM Plex Mono for figures, Akira for page titles and one hero
    /// number per screen.
    enum Face {
        static let regular = "IBMPlexSans"
        static let medium = "IBMPlexSans-Medm"
        static let semibold = "IBMPlexSans-SmBld"
        static let bold = "IBMPlexSans-Bold"
        static let monoRegular = "IBMPlexMono"
        static let monoMedium = "IBMPlexMono-Medm"
        static let monoSemibold = "IBMPlexMono-SmBld"
        static let akira = "AkiraExpanded-SuperBold"
    }

    /// Sets Plex in the UIKit chrome SwiftUI doesn't reach (navigation bars, segmented controls).
    static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        if let large = UIFont(name: Face.bold, size: 34) { nav.largeTitleTextAttributes = [.font: large] }
        if let title = UIFont(name: Face.bold, size: 17) { nav.titleTextAttributes = [.font: title] }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        edge.titleTextAttributes = nav.titleTextAttributes
        UINavigationBar.appearance().scrollEdgeAppearance = edge

        if let tab = UIFont(name: Face.medium, size: 10) {
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .selected)
        }
        if let seg = UIFont(name: Face.medium, size: 13), let segOn = UIFont(name: Face.semibold, size: 13) {
            UISegmentedControl.appearance().setTitleTextAttributes([.font: seg], for: .normal)
            UISegmentedControl.appearance().setTitleTextAttributes([.font: segOn], for: .selected)
        }
    }
}

extension Font {
    /// Plex Sans at a text style's size, scaling with Dynamic Type.
    static func brand(_ style: Font.TextStyle, weight: Brand.Weight = .regular) -> Font {
        .custom(weight.face, size: Brand.size(for: style), relativeTo: style)
    }

    /// Plex Mono for figures, so columns of numbers line up.
    static func num(_ style: Font.TextStyle, weight: Brand.Weight = .regular) -> Font {
        .custom(weight.monoFace, size: Brand.size(for: style), relativeTo: style)
    }

    /// Plex Mono at an exact size (large live figures).
    static func num(size: CGFloat, weight: Brand.Weight = .semibold) -> Font {
        .custom(weight.monoFace, size: size)
    }

    /// Akira for one hero number per screen.
    static func hero(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(Brand.Face.akira, size: size, relativeTo: style)
    }
}

extension Brand {
    enum Weight {
        case regular, medium, semibold, bold
        var face: String {
            switch self {
            case .regular: Face.regular
            case .medium: Face.medium
            case .semibold: Face.semibold
            case .bold: Face.bold
            }
        }
        /// Mono has no bold in the bundle; bold figures use semibold.
        var monoFace: String {
            switch self {
            case .regular: Face.monoRegular
            case .medium: Face.monoMedium
            case .semibold, .bold: Face.monoSemibold
            }
        }
    }

    /// iOS default sizes for each text style at the standard Dynamic Type setting.
    static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

extension Color {
    /// 0xRRGGBB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that switches with light and dark mode.
    init(light: UIColor, dark: UIColor) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Akira's slant, matching the logotype (Akira itself is upright).
struct AkiraSlant: ViewModifier {
    func body(content: Content) -> some View {
        content.transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.21, d: 1, tx: 0, ty: 0))
    }
}

extension View {
    func akiraSlant() -> some View { modifier(AkiraSlant()) }
}
