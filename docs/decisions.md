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
- **W'bal comes from the Intervals `w_bal` stream**, not computed in the app, so it
  matches the website.
- Workout building stays on desktop/Claude. The app only does light calendar edits
  (move, delete, add a note).
- Build order: v2.0 (activity view + quick log) before v2.1 (Today + Week).
