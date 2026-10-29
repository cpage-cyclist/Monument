# Decisions

Fixed choices for Monument (formerly Run Guide). Change one only on purpose, and update this file when you do.

## Name and identity

- The app is **Monument**, in `cpage-cyclist/Monument`, seeded with Run Guide's full history.
  `cpage-cyclist/run-guide` stays as the source of the installed Run Guide build.
- Monument is a **separate app** with bundle ID `com.cpage.monument` and Strava callback
  scheme `monument://`. **Run Guide** (`com.cpage.runguide`, `runguide://`) stays installed
  as-is as the stable run app until Monument's run player replaces it.
- Monument starts with its own data: Intervals credentials, Strava connection and routes
  are set up again in it.
- Code, target and package names keep their Run Guide names.

## Build and install

- **No local Xcode.** Both Macs are Intel, so current Xcode can't run locally. All
  builds happen in **GitHub Actions** (`.github/workflows/ci.yml`), which runs the
  `RunGuideCore` tests, validates sample FIT files and produces an unsigned `.ipa`.
- **Sideloaded with Sideloadly** using a free Apple ID. The app needs re-signing every
  7 days.
- **No real push notifications** (free Apple ID). Anything "notify me" is a local
  notification or a check when the app opens.

## Recording and upload (v1, kept in v2)

- Runs are recorded as **FIT** files: typed laps (warm-up / active / rest / cool-down),
  real pause events, room for future sensors.
- **Heart-rate straps** supported over Bluetooth.
- Runs upload to **both Intervals.icu and Strava**. Strava auto-import in Intervals is
  **off**, so runs don't arrive twice.
- Routes are planned in **Strava** (GPX), with short turn cues given ahead of time.
- Phone-GPS distance imprecision is **accepted**.
- Cues guide structure; they don't nag about pace (runs are done by feel).

## Code

- Pure logic lives in `RunGuideCore` with tests; the `RunGuide/` app layer wires it to
  the system. v2 data shaping and maths (stream smoothing, selection stats, W'bal
  markers) follow the same rule.
- Xcode project generated from `project.yml` with XcodeGen; `.xcodeproj` and
  `Info.plist` are never committed.
- Intervals API key lives in the **Keychain only**.

## v2

- v2 is a phone-first Intervals.icu client; the run-cue player stays as one part of it.
- Copy the Intervals web layout faithfully, then fix what's poor on a phone.
- Monument Almanac is about **insights, not coaching**, with room to grow a collective/social
  side later.
- **Intervals stays the source of truth** for now. Removing the dependency is a longer-term
  option, to be decided after trials.
- W'bal shows Intervals' `w_bal` stream, Monument's own, or both (see below).
- The **Calendar tab replaces the Week tab**, with fitness, fatigue and form projected forward
  from planned load from the first version.
- Monument has a **proper workout builder** on the phone. It's sport-agnostic: sport is a
  property of the workout.
- **Record** is sport-agnostic: the sport is chosen before starting and locked for the session.
  Cycling route cues get a bigger warning buffer than running (about 500 m vs 100 m).
- **Record** offers Run, Ride and Walk, plus **Just record** (laps by hand, carries on until
  stopped). Sessions play from Intervals workout text for any sport, with power targets shown in
  watts from the latest FTP. Rides show km/h, say speed rather than pace and split every 5 km.
- **Power meters and cadence sensors** over Bluetooth (Cycling Power 0x1818, CSC 0x1816), paired
  in Settings like the HR strap. Cadence comes from the power meter's crank data when it sends
  it. Live 3 s power against the step's target band; power and cadence go in the FIT file
  (records, laps, session, with normalised power).
- A **Rider tab**: one page, no scrolling, a top-trumps card of best efforts and stats, a clean
  link to settings, and launch points into the rest of the app.
- The **Rider card's thresholds follow its period toggle**. Monument fits OmPD to that period's
  curve (falling back to the 90-day fit, labelled "Monument 90d", when it won't fit). Intervals FTP
  is today's setting over 42 days, and over a year or all time the highest FTP set on any ride in
  the span ("Peak FTP"). **W/kg uses a weigh-in within two weeks of the ride that set the effort**
  (else today's weight), and the hero likewise for the ride its FTP belongs to. The weight Intervals
  stamps on a ride isn't trusted: back-dated weigh-ins only change their own day, so rides in between
  keep a stale default. Workouts still use today's thresholds.
- The builder **reads and writes Intervals workout text** (what's in the step text on the web), so
  Intervals still works out time and load and syncs to the head unit. `m` always means minutes;
  metres are written `mtr`. Blocks can repeat, one level deep, as in Intervals.
- The builder is a **visual block editor with a structure chart**, with "Edit as text" for the raw
  Intervals text. It edits new workouts, planned sessions and library workouts, and saves to a
  calendar day and/or a library folder. Targets: power (% FTP, watts, zones, ramps, cadence),
  heart rate (% max, LTHR, zones), pace (% threshold, min/km, zones), or none with a cue.
- The **Calendar** is a month grid with the chosen day's sessions underneath and a fitness,
  fatigue and form strip across the month (projected days dashed).
- Build order (see `v2-scope.md`): Calendar, then workout builder, then Record, then Rider,
  then insights (power profile, dFRC, custom chart builder).

## Monument power profile and W'bal

- The W'bal chart can show **Intervals' W'bal** (its `w_bal` stream, from the FTP and W'
  set by hand in Intervals), **Monument's**, or **both** (Intervals' dashed). Efforts,
  markers and the breakdown follow whichever is shown (Monument's when both).
- Monument's profile is the **omni-domain power-duration model** (OmPD, Puchowicz, Baker & Clarke
  2020): Pmax, CP, W′ and a log-linear fade past 30 min (TCPmax 1800 s), fitted to best efforts
  from 1 s to 2 h by least squares on relative error. **Monument's FTP is the modelled hour power.**
  Where the curve has no sprint or long efforts it falls back to the 2-parameter fit below.
- **One app-wide setting** (Settings › Power profile) picks thresholds from Intervals or Monument.
  It sets workout target watts (builder, Record, Today), the Rider card and the W′bal chart's
  default; the other source is shown alongside.
- The 2-parameter fallback: a **2-parameter critical power model**
  (work = CP·t + W′, least squares) on best efforts at 3, 4, 5, 7, 10, 12, 15 and 20 min
  from the Intervals power curve for the **90 days up to and including the ride**. Fits that
  aren't physiologically plausible are rejected and Intervals' W'bal is shown instead.
- Monument's W'bal uses **Skiba's differential model**: above CP, W′ drains joule for joule;
  below CP it refills at (W′ − W)·(CP − P)/W′, solved exactly per sample. Stops count as rest
  at 0 W.
- The model lives in `RunGuideCore/PowerProfile.swift` so new fits (3-parameter, Pmax) and
  new balance models (e.g. CP/W′ that degrade with work done) can sit alongside it.
- The quick log records **carbs in g/h**. Intervals stores carbs per activity as total grams
  (`carbs_ingested`), so Monument converts using moving time and shows g/h back. It's logged
  as a tag for later W'bal work (e.g. how fuelling relates to how W′ holds up on long rides).

## Look and feel

- Monument Almanac branding: forest green `#00321F`, light green `#7F9990`, Helvetica Neue for all
  text, Akira (demo, personal use) only for the wordmark artwork and hero numbers.
- The ridge header stacks the five monuments' profiles at 15% light green on white (10% white on
  forest in dark mode), squashed to 40% height; the page takes the colour of all five overlapping.
- **Data colours** (`Brand.Data`) come from the brand itself: power forest #00321F, W′bal sage
  #7F9990, heart rate gold #AA954B, cadence bronze #A96034, speed/pace silver #A0978A, altitude
  hairline #121212. They're muted on purpose, so **shape carries identity too**: W′bal and altitude
  are shaded areas (altitude faint), speed/pace is dashed, power/HR/cadence are solid lines, and
  every series is named in the chips and readout. (Silver and sage alone are too close to tell
  apart; the area/dash split is what separates them.) Charts sit on a **white surface in light and
  dark mode**.
- The **activity view never scrolls**: key figures, overlay chips, one chart filling the space,
  and a fixed bottom panel whose tabs page rather than scroll. **Pinch to zoom**, zoom to a
  selection from the readout, double-tap or Reset for the whole ride; a zoomed chart shows an
  overview strip to pan along.
- **Laps are the device's own laps by default**, read from the activity's original FIT
  (`/activity/{id}/file`), with every figure worked out from the streams. A toggle in the Laps tab
  switches to Intervals' detected intervals, and the app falls back to them when there's no
  original file (Strava imports) or only one lap.
- **Medals** mark peak efforts that rank 1st, 2nd or 3rd over the last year (slanted gold/silver/
  bronze bar) or all time (the logotype's pair of bars side by side). All time outranks
  year. Ranks come from Intervals' `power-curves` with `curves=1y,all&subMaxEfforts=2`.

## Visual direction (October 2026 review)

- **Type: IBM Plex Sans** for text and **IBM Plex Mono** for numbers, replacing Helvetica Neue.
  **Boxes stay**: cards keep their hairline outline (layout D from the review canvas).
- **Akira page titles in the ridge header**, in place of the MONUMENT wordmark: TODAY, CALENDAR,
  ACTIVITIES, RECORD, RIDER, set slanted like the logotype at one shared size. The big Helvetica
  title under the header goes.
- **Pushed screens** (activity detail and the like) get a compact ridge header with a back chevron
  and a **short Akira line** (sport and date, e.g. RIDE · 24 OCT). User-written names never go in
  Akira: they sit underneath in Plex, two lines at most, then truncate.
- **Ridge footer**: at the bottom of a scrolling page the ridges darken into forest to meet the tab
  bar, carrying the MONUMENT ALMANAC lockup. It doubles as pull up to load more (older activities).
  The Record live screen uses the same footer behind Pause, Lap and End.
- **Tab changes slide** in the direction of travel: a full-width push of just the two pages
  involved, moving together, with no crossfade. **Swiping sideways** on any of the five main pages
  does the same, following the finger (a short fling is enough); pushed screens don't swipe, so
  the system back-swipe and chart gestures are untouched. The Calendar no longer swipes between
  months (arrows only), and its scrubbable charts never start a tab swipe.
- **Pull-to-refresh taps** (a firm haptic) the moment the pull passes the trigger point.
- **The gold bar is Monument's success mark**: the logotype's slanted bar, one shape everywhere –
  it slides in after the page title when a pull-to-refresh lands, marks a Strava route that's on
  the phone, and makes up the best-effort medals.
- **One Akira hero per screen**: Today form, Calendar the selected week's load, Activity NP,
  Record the countdown, Rider FTP W/kg.
- **Fitness, fatigue and form colours**: fitness forest, fatigue bronze, form gold, on the Calendar
  chart and Today's figures alike. Cards showing coloured data sit on white.
- Every screen comes into the Monument style, including Record's start and summary screens,
  Library and Settings (no stock iOS grey lists).

## Routes (October 2026)

- The **Strava route list is kept on the phone** and opens from that copy; it's refetched only
  when over 12 hours old or on a pull down. Each route's **thumbnail is its shape** from Strava's
  summary polyline (no map tiles, no GPX download), and routes on the phone keep a thinned outline
  of their own. A route edited on Strava since import is flagged to update.
- **Record shows the last three routes for the chosen sport** (most recently used or added), then
  one link to the full **route library**: search, Runs / Rides / All, swipe to rename or delete,
  and the ways to add more (Strava, GPX/TCX file). Files with no sport show under both.
- Intervals and Strava requests never answer from the system URL cache; the app's own cache
  decides freshness, so a forced refresh always goes to the network.
