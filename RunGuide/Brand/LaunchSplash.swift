import SwiftUI

/// Opening animation. The full MONUMENT ALMANAC lockup sits over the spread ridges; then ALMANAC
/// and the gold bars drop away while MONUMENT crossfades to the standalone wordmark (retracting
/// the extended M and T), and the wordmark and ridges rise together into Today's header,
/// with Today's content and the tab bar rising in from below.
/// It ends exactly where Today's header sits at rest, so removing it is invisible.
struct LaunchSplash: View {
    @ObservedObject var launch: LaunchState
    var onFinish: () -> Void

    private enum Phase { case lockup, dropped, settled }
    @State private var phase: Phase = .lockup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            let fullHeight = geo.size.height + top + geo.safeAreaInsets.bottom
            let restHeight = top + Brand.Header.body
            let settled = phase == .settled

            let lockupWidth = geo.size.width * 0.84
            let scale = settled ? Brand.Header.wordmarkWidth / lockupWidth : 1
            let x = settled ? Brand.Header.wordmarkInset.x : (geo.size.width - lockupWidth) / 2
            let y = settled ? top + Brand.Header.wordmarkInset.y : fullHeight * 0.40

            ZStack(alignment: .topLeading) {
                RidgeBackdrop(spread: settled ? Brand.Header.restSpread : Brand.Header.launchSpread)
                    .frame(width: geo.size.width, height: settled ? restHeight : fullHeight)

                Lockup(width: lockupWidth,
                       drop: phase == .lockup ? 0 : 1,
                       crossfade: phase == .lockup ? 0 : 1)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: x, y: y)
            }
            .frame(width: geo.size.width, height: fullHeight, alignment: .topLeading)
            .ignoresSafeArea()
        }
        .allowsHitTesting(phase != .settled)
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
        withAnimation(.spring(response: 0.85, dampingFraction: 0.9)) {
            phase = .settled
            launch.revealed = true
        }
        try? await Task.sleep(for: .milliseconds(1000))
        onFinish()
    }
}
