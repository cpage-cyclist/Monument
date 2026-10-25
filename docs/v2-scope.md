# Monument (v2) — scope

## Goal

Grow Run Guide into Monument: a fast, phone-first Intervals.icu client, with the run-cue player
kept as one part of it. The Intervals web view is already close to right: copy its
layout faithfully, then fix what it does badly on a phone — it's slow and clunky, its
charts are hard to read on a small screen, logging is fiddly, and the selection
breakdown is weak.

v1 (the spoken-cue player, FIT recording, HR strap, Intervals + Strava upload) stays as
it is and becomes the "Start" action for planned runs.

## v2.0 — Activity view + quick log (build first)

### Activity view

- Stacked charts sharing one timeline: power, HR, cadence, speed/pace and altitude,
  with the same smoothing options as the web.
- **W'bal chart (must-have).** Use the Intervals API `w_bal` stream directly so it
  matches the website (calculated from CP/W' settings, roughly 31 kJ). Shown as its own
  panel under power or as a toggleable overlay. Mark the lowest point and the kJ spent
  per effort.
- **Selection breakdown, TrainingPeaks-style:**
  - Long-press and drag across a chart to select a range. A normal drag only scrubs.
  - Tapping a lap or detected interval selects it.
  - Tapping a peak in the best-efforts list (5s / 1m / 5m / 20m …) highlights where it
    happened on the chart.
  - The panel shows duration, distance, average and NP power, W/kg, IF, load, average
    and max HR, cadence, speed/pace, elevation gain, decoupling, and W'bal at the start,
    end and lowest point of the selection. Optionally compares each figure with the
    whole activity.
- Laps/intervals table, each row tappable into the same breakdown.

### Quick log

- One screen: RPE slider (1–10), feel (1–5), optional one-line note. About three
  seconds to complete.
- Optional wellness fields (sleep, soreness, weight) that can be hidden.
- Prompt on app open when an activity is unlogged.

## v2.1 — Today + Week

- **Today:** next planned session (name, duration, load, step structure), a "Start"
  button for runs that opens the voice-cue player, the last activity with a log prompt,
  and fitness/fatigue/form charts.
- **Week:** seven days centred on today, swipeable a week at a time, planned vs completed
  per day, with move, delete and add-a-note edits. Replaced by the Calendar in v2.2.
- **Speed:** local cache so screens open instantly and refresh in the background.

## Built so far

- v2.0 and v2.1 above.
- Monument Almanac brand: theme, ridge header with pull-to-refresh spread and collapse,
  launch animation, forest green tab bar, medals for top-three peak efforts.
- Monument's own W'bal from a fitted 2-parameter CP profile, alongside Intervals'.

## Next, in order

1. **v2.2 Calendar** (replaces Week): planned and completed sessions, the existing edits,
   and fitness, fatigue and form projected forward from planned load.
2. **v2.3 Workout builder:** sport-agnostic structured workouts, saved to the calendar and
   the Intervals library.
3. **v2.4 Record:** sport-agnostic recording grown from the run player. Sport chosen and
   locked before starting; about 500 m route cue warning for cycling; plays builder workouts.
4. **v2.5 Rider:** single top-trumps page of best efforts and stats, settings link, launch
   points into the app.
5. **Insights:** toggle Monument's power profile against the Intervals values, dFRC
   alongside W'bal, W' decay over long efforts, then a WKO5-style custom chart builder.

Also to come: a further pass on the activity view, and a full visual polish pass across the app,
including bringing the workout builder's step and text editors into the Monument style used on
Today. Ideas to consider for more Akira: page titles in slanted Akira like the logotype; one hero
number per screen (form on Today, NP or load on activities, week load on the Calendar, FTP W/kg on
Rider); Record's live countdown and watts; "NEW BEST" / "2ND ALL TIME" with best-effort medals.

## API notes

- The Intervals.icu API exposes calendar/events, activities, streams (including
  `w_bal`), wellness, fitness, power curves and the workout library.
- Activities recorded in the **Strava app** come back as placeholders via the API
  (Strava restricts sharing). Activities only appear in v2 if they reach Intervals
  directly: the app's own run upload, or Wahoo/Garmin syncing straight to Intervals.
- The custom Intervals MCP connector (`cpage-cyclist/intervals-mcp`, hosted on Render)
  is useful for checking what the API returns while building.
