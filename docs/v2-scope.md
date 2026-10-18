# Run Guide v2 — scope

## Goal

Grow Run Guide into a fast, phone-first Intervals.icu client, with the run-cue player
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
  and a fitness/fatigue/form readout (numbers only).
- **Week:** swipeable week view, planned vs completed per day. Light edits only: move a
  session to another day, delete it, add a note. Workout building stays on
  desktop/Claude.
- **Speed:** local cache so screens open instantly and refresh in the background.

## API notes

- The Intervals.icu API exposes calendar/events, activities, streams (including
  `w_bal`), wellness, fitness, power curves and the workout library.
- Activities recorded in the **Strava app** come back as placeholders via the API
  (Strava restricts sharing). Activities only appear in v2 if they reach Intervals
  directly: Run Guide's own upload, or Wahoo/Garmin syncing straight to Intervals.
- The custom Intervals MCP connector (`cpage-cyclist/intervals-mcp`, hosted on Render)
  is useful for checking what the API returns while building.
