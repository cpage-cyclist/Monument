# Monument

A fast, phone-first Intervals.icu client for iPhone, with a hands-free run-cue player built in.

Monument started life as **Run Guide**, and Run Guide lives on inside it as the run player.
It loads a planned run from Intervals.icu, then talks you through it with the phone in
your pocket. Every step ends on its own terms, distance by GPS or time by the clock, so
mixed sessions like 5 × (1 km rep + 90 s float) auto-lap with no taps.

The rest of the app (activity charts with W'bal, selection breakdowns, quick RPE logging,
Today and Week views) is being built; see `docs/v2-scope.md`.

What you hear on a 5 × 1 km session:

- At each step start: "Rep 2 of 5. 1 kilometre at 4 minutes per kilometre."
- 100 m before the end of a rep: "100 metres to go. Next, Float. 90 seconds…"
- 15 s before the end of a float: "15 seconds. Next, Rep 3 of 5…"
- When a step ends: "Rep 2 done, 3 58 per kilometre." (can be switched off)
- On steps of 2 km+ or 10 min+: a split each km.

Music keeps playing and dips while it speaks.

## Install on your iPhone

The Macs are Intel, so the app is built in GitHub Actions rather than local Xcode.

1. Every push to `main` builds the app. Open the latest **CI** run under the repo's
   **Actions** tab and download the **Monument-unsigned-ipa** artifact (unzip it to get
   `Monument-unsigned.ipa`). To build another branch, use **Run workflow** on the CI page.
2. Open **Sideloadly**, plug in the iPhone, drop the .ipa in, enter your Apple ID and
   press **Start**.
   - First time only: on the phone, turn on **Settings › Privacy & Security › Developer Mode**
     (it restarts), then trust your Apple ID under **Settings › General › VPN & Device Management**.
3. With a free Apple ID the app stops opening after **7 days**; re-sign it in Sideloadly.
   There are no push notifications on a free Apple ID, so reminders are local or shown
   when the app opens.

Monument (`com.cpage.monument`) installs as its own app next to Run Guide, which keeps its
data. Add your Intervals athlete ID and API key in Monument's Settings. To use Strava in
Monument, connect it again there; the same Strava API app works for both.

## First run

1. Tap the gear and add your Intervals **athlete ID** and **API key** (intervals.icu ›
   Settings › Developer Settings). The key is kept in the phone's Keychain.
2. Allow location **While Using the App** when asked.
3. Pick today's run, wait for "GPS ready", press **Start**, then lock the phone.

Buttons on the run screen: **Pause/Resume**, **Lap** (end the current step now) and
**End**. The summary at the end can be shared as text, e.g. pasted back to Claude for
logging.

## Recording, FIT files and heart rate

- Every run is recorded (GPS track, heart rate, laps and pauses) and saved as a
  **.fit file** in the Files app under On My iPhone › Monument › Runs, and in the app
  under **Saved runs**.
- Laps are typed: warm-up, active (reps), rest (floats/recoveries) and cool-down, with
  pauses recorded as real timer stops.
- When the session ends you choose **Save and upload** or **Discard run**. Nothing goes
  to Intervals or Strava until you tap Save (each can be switched off in Settings). If an
  upload fails, retry from the summary screen or Saved runs.
- **Strava upload** sends the same FIT file (laps, HR) once Strava is connected with
  upload permission. Turn off Strava downloads in Intervals so runs don't arrive twice.
- **Voice:** pick any English voice on the phone in Settings. Premium/Enhanced voices
  sound far better; download them in iPhone Settings › Accessibility › Spoken Content ›
  Voices.
- **Heart rate:** in Settings, tap *Pair a heart-rate strap* with the strap on. Any
  Bluetooth chest strap works; it reconnects by itself for later runs.

## Routes

- **Straight from Strava:** one-off, create an API app on strava.com (Settings › My API
  Application, Authorization Callback Domain `localhost`), paste its Client ID and Secret
  into Monument Settings and tap *Connect Strava*. Then *Your Strava routes* lists your
  saved routes (private ones too); tap one to import it, tap again to refresh it.
- Or export a route as **GPX** and AirDrop/share it to Monument, or *Import a route file*.
  TCX works too.
- Turns are worked out from the line: bends within 40 m merge into one cue, jinks that
  net out straight become **"Straight on"**, weaving junctions are called **"Tricky
  junction, …"**.
- You hear "In 100 metres, turn left[, then right]" and "Turn left now". Turn cues cut in
  over session cues; anything interrupted is repeated straight after.
- **Off route** after ~6 s more than ~40 m from the line, then **Back on route**.
- **Loops** (start and finish within 50 m) can **Repeat laps**: "Lap 2", "Lap 3"…; a
  shared stub at the start is only run on lap 1, and the junction turn is called at the
  end of every lap. Otherwise you hear **End of route** at the finish.
- Run a route on its own (Routes › a route › *Run this route*) or pick one on any
  session's preview screen.

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

- `RunGuideCore/` holds the session parser, the auto-lap and cue engine, the speech
  phrasing, the activity recorder and the FIT encoder as a Swift package with tests
  (`swift test --package-path RunGuideCore`).
- `RunGuide/` is the iPhone app: GPS (`LocationTracker`), voice (`Announcer`), heart
  rate (`HeartRateMonitor`), saved runs (`RunStore`), the Intervals API
  (`IntervalsClient`) and the screens.
- `scripts/validate_fit.py` checks FIT files with Garmin's official FIT SDK.
- `design/monument-logo-2000.png` is the master logo; the app icon is a 1024 px copy in
  `RunGuide/Assets.xcassets/AppIcon.appiconset`.
- `project.yml` generates the Xcode project; the `.xcodeproj` itself isn't committed.
- GitHub Actions runs the tests, validates sample FIT files with Garmin's SDK and builds
  the app on every push to `main`.
