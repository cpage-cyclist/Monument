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
- Monument's profile is fitted per ride: a **2-parameter critical power model**
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
- **Medals** mark peak efforts that rank 1st, 2nd or 3rd over the last year (slanted gold/silver/
  bronze bar) or all time (inverted: solid metal badge with the bar cut out). All time outranks
  year. Ranks come from Intervals' `power-curves` with `curves=1y,all&subMaxEfforts=2`.
