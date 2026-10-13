# Run Guide – notes for Claude

Personal iPhone app (SwiftUI, iOS 17+) that speaks structured run sessions pulled from
Intervals.icu and auto-laps mixed distance/time steps.

- Session logic lives in `RunGuideCore` (pure Swift, no UIKit/CoreLocation) so it can be
  tested with `swift test --package-path RunGuideCore`. Keep new logic there with tests.
- The app layer (`RunGuide/`) only wires GPS, clock and speech to `SessionEngine`.
- The Xcode project is generated: edit `project.yml`, then `xcodegen generate`.
  Never commit `RunGuide.xcodeproj` or `RunGuide/Info.plist`.
- Build check without signing:
  `xcodebuild -project RunGuide.xcodeproj -scheme RunGuide -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- The Intervals API key is stored in the Keychain only. Never hardcode it or commit it.
- The user runs sessions by feel: cues should guide structure, not nag about pace.
