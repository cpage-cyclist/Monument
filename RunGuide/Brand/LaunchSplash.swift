import SwiftUI

/// Opening animation. The full MONUMENT ALMANAC lockup sits over the spread ridges; ALMANAC and
/// the gold bars drop away while MONUMENT crossfades to the standalone wordmark (retracting the
/// extended M and T). Then the whole screen scrolls up as one: MONUMENT carries on up and off the
/// top, the ridges compact into the header, and the first page's Akira title comes up from below
/// the bottom edge, at the same pace as the page content and the tab bar, into its place in the
/// header. It ends exactly where that header sits at rest, then fades away, so the handover is
/// invisible.
struct LaunchSplash: View {
    @ObservedObject var launch: LaunchState
    /// The first page's title, drawn here so it can rise above the splash's ridges.
    var title: String
    var onFinish: () -> Void

    private enum Phase { case lockup, dropped, settled }
    @State private var phase: Phase = .lockup
    @State private var fading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One curve for everything that scrolls, so the wordmark, title and content keep pace.
    static let scroll = Animation.spring(duration: 0.95, bounce: 0)

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            let fullHeight = geo.size.height + top + geo.safeAreaInsets.bottom
            let restHeight = top + Brand.Header.body
            let settled = phase == .settled
            let travel = launch.rise

            let lockupWidth = geo.size.width * 0.84
            let lockupY = fullHeight * 0.40

            ZStack(alignment: .topLeading) {
                RidgeBackdrop(spread: settled ? Brand.Header.restSpread : Brand.Header.launchSpread)
                    .frame(width: geo.size.width, height: settled ? restHeight : fullHeight)

                // MONUMENT scrolls straight up and off the top.
                Lockup(width: lockupWidth,
                       drop: phase == .lockup ? 0 : 1,
                       crossfade: phase == .lockup ? 0 : 1)
                    .offset(x: (geo.size.width - lockupWidth) / 2,
                            y: settled ? lockupY - travel : lockupY)

                // The page title comes up from below into the header, laid out exactly as
                // PullRidgeHeader lays it out.
                AkiraTitle(text: title)
                    .frame(maxWidth: geo.size.width - 90, alignment: .leading)
                    .padding(.leading, Brand.Header.wordmarkInset.x)
                    .padding(.top, top + Brand.Header.wordmarkInset.y)
                    .offset(y: settled ? 0 : travel)
            }
            .frame(width: geo.size.width, height: fullHeight, alignment: .topLeading)
            .ignoresSafeArea()
            .onAppear { launch.rise = fullHeight }
        }
        .opacity(fading ? 0 : 1)
        .allowsHitTesting(phase != .settled)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            launch.revealed = true
            try? await Task.sleep(for: .milliseconds(500))
            onFinish()
            return
        }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(.easeIn(duration: 0.4)) { phase = .dropped }
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(Self.scroll) {
            phase = .settled
            launch.revealed = true
        }
        try? await Task.sleep(for: .milliseconds(1000))
        // Fade rather than cut, so the header's button arrives softly.
        withAnimation(.easeOut(duration: 0.2)) { fading = true }
        try? await Task.sleep(for: .milliseconds(220))
        onFinish()
    }
}
