# Monument – notes for Claude

Personal iPhone app (SwiftUI, iOS 17+): a fast, phone-first Intervals.icu client. It grew
out of Run Guide, the spoken run-cue player that pulls structured runs from Intervals and
auto-laps mixed distance/time steps; Run Guide lives on inside Monument as the run player.
Scope is in `docs/v2-scope.md`, fixed choices in `docs/decisions.md`.

- Monument is its own app (`com.cpage.monument`, Strava callback `monument://`), installed
  alongside Run Guide (`com.cpage.runguide`, `runguide://`), which stays as the stable run
  app. Code, targets and the `RunGuideCore` package keep their Run Guide names.
- There's no local Xcode (Intel Macs). Builds and tests run in GitHub Actions; the
  unsigned .ipa is sideloaded with Sideloadly.

- Session logic lives in `RunGuideCore` (pure Swift, no UIKit/CoreLocation) so it can be
  tested with `swift test --package-path RunGuideCore`. Keep new logic there with tests.
- The app layer (`RunGuide/`) wires system services (GPS, speech, Bluetooth, network, storage)
  to `RunGuideCore`; keep data shaping and maths in the package.
- The Xcode project is generated: edit `project.yml`, then `xcodegen generate`.
  Never commit `RunGuide.xcodeproj` or `RunGuide/Info.plist`.
- Build check without signing:
  `xcodebuild -project RunGuide.xcodeproj -scheme RunGuide -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- The Intervals API key is stored in the Keychain only. Never hardcode it or commit it.
- The user runs sessions by feel: cues should guide structure, not nag about pace.
