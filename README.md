# run-guide

Simple app which dictates workouts while running.

Run Guide loads a planned run from Intervals.icu, then talks you through it with the
phone in your pocket. Every step ends on its own terms, distance by GPS or time by the
clock, so mixed sessions like 5 × (1 km rep + 90 s float) auto-lap with no taps.

What you hear on a 5 × 1 km session:

- At each step start: "Rep 2 of 5. 1 kilometre at 4 minutes per kilometre."
- 100 m before the end of a rep: "100 metres to go. Next, Float. 90 seconds…"
- 15 s before the end of a float: "15 seconds. Next, Rep 3 of 5…"
- When a step ends: "Rep 2 done, 3 58 per kilometre." (can be switched off)
- On steps of 2 km+ or 10 min+: a split each km.

Music keeps playing and dips while it speaks.

## Install on your iPhone (from the iMac)

1. Install the tools (once):
   ```sh
   brew install xcodegen
   ```
   and Xcode from the App Store.
2. Get the code and generate the Xcode project:
   ```sh
   git clone https://github.com/cpage-cyclist/run-guide.git
   cd run-guide
   xcodegen generate
   open RunGuide.xcodeproj
   ```
3. In Xcode, select the **RunGuide** target, open **Signing & Capabilities** and pick
   your Apple ID under **Team** (Xcode › Settings › Accounts to add it). If it says the
   bundle identifier is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`,
   run `xcodegen generate` again and reopen.
4. Plug in the iPhone, choose it as the run destination at the top of Xcode and press ▶.
   - First time only: on the phone, turn on **Settings › Privacy & Security › Developer Mode**
     (it restarts), then trust your developer profile under
     **Settings › General › VPN & Device Management**.
5. With a free Apple ID the app stops opening after **7 days**. Plug in and press ▶ again
   to renew it. A paid developer account makes it last a year.

## First run

1. Tap the gear and add your Intervals **athlete ID** and **API key** (intervals.icu ›
   Settings › Developer Settings). The key is kept in the phone's Keychain.
2. Allow location **While Using the App** when asked.
3. Pick today's run, wait for "GPS ready", press **Start**, then lock the phone.

Buttons on the run screen: **Pause/Resume**, **Lap** (end the current step now) and
**End**. The summary at the end can be shared as text, e.g. pasted back to Claude for
logging.

Run Guide doesn't upload the run anywhere yet, so keep recording in the Wahoo app
alongside it.

## Session format

The same text as the Intervals workout builder:

```
Warmup
- 2km 5:00-5:30/km Pace

Main set 5x
- 1km 4:00/km Pace
- Float 90s 5:00-5:30/km Pace

Cooldown
- 2km 5:00-5:30/km Pace
```

- Time: `90s`, `5m`, `1m30s`, `1h30m`. Distance: `2km`, `2.5km`, `400mtr`, `1mi`.
  In Intervals `m` means minutes, but `400m` (100 or more) is read as metres.
- Text before the amount becomes the spoken cue (`Float`, `Block 1`).
- A line ending in `5x` repeats the steps under it until a blank line.
- A step with no amount (e.g. `- Easy jog`) lasts until you tap Lap.

## Known limits

- Phone GPS drifts by a few per cent, so a "1 km" rep may be 980–1,020 m.
- Distance pauses when GPS accuracy is worse than 25 m (e.g. under thick tree cover).

## Code layout

- `RunGuideCore/` holds the session parser, the auto-lap and cue engine, and the speech
  phrasing as a Swift package with tests (`swift test --package-path RunGuideCore`).
- `RunGuide/` is the iPhone app: GPS (`LocationTracker`), voice (`Announcer`),
  the Intervals API (`IntervalsClient`) and the screens.
- `project.yml` generates the Xcode project; the `.xcodeproj` itself isn't committed.
- GitHub Actions runs the tests and builds the app on every push to `main`.
