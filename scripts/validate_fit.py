"""Check FIT files written by Run Guide with Garmin's official FIT SDK.

Usage: python3 scripts/validate_fit.py FILE [--laps N] [--hr] [--gps] [--sport S] [--power]
Exits non-zero if the file is invalid or doesn't contain what's expected.
"""
import argparse
import sys

from garmin_fit_sdk import Decoder, Stream


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--laps", type=int)
    parser.add_argument("--hr", action="store_true", help="expect heart rate")
    parser.add_argument("--gps", action="store_true", help="expect positions")
    parser.add_argument("--sport", default="running", help="expected session sport")
    parser.add_argument("--power", action="store_true", help="expect power and cadence")
    args = parser.parse_args()

    check = Decoder(Stream.from_file(args.file))
    if not check.is_fit():
        fail("not a FIT file")
    check = Decoder(Stream.from_file(args.file))
    if not check.check_integrity():
        fail("integrity (CRC) check failed")

    messages, errors = Decoder(Stream.from_file(args.file)).read()
    if errors:
        fail(f"decode errors: {errors}")

    for key in ["file_id_mesgs", "event_mesgs", "record_mesgs", "lap_mesgs", "session_mesgs", "activity_mesgs"]:
        if not messages.get(key):
            fail(f"missing {key}")

    file_id = messages["file_id_mesgs"][0]
    if file_id.get("type") != "activity":
        fail(f"file type is {file_id.get('type')}")

    records = messages["record_mesgs"]
    laps = messages["lap_mesgs"]
    session = messages["session_mesgs"][0]

    times = [r["timestamp"] for r in records]
    if times != sorted(times):
        fail("record timestamps go backwards")

    if session.get("sport") != args.sport:
        fail(f"session sport is {session.get('sport')}")
    if session.get("num_laps") != len(laps):
        fail(f"session says {session.get('num_laps')} laps, file has {len(laps)}")
    if args.laps is not None and len(laps) != args.laps:
        fail(f"expected {args.laps} laps, got {len(laps)}")

    lap_distance = sum(l.get("total_distance", 0) for l in laps)
    if abs(lap_distance - session["total_distance"]) > 5:
        fail(f"laps add to {lap_distance} m but session is {session['total_distance']} m")

    if session["total_elapsed_time"] < session["total_timer_time"]:
        fail("timer time is longer than elapsed time")

    if args.hr and not any(r.get("heart_rate") for r in records):
        fail("no heart rate in records")
    if not args.hr and any(r.get("heart_rate") for r in records):
        fail("unexpected heart rate in records")
    if args.gps and not any(r.get("position_lat") is not None for r in records):
        fail("no positions in records")

    if args.power:
        if not any(r.get("power") for r in records):
            fail("no power in records")
        if not any(r.get("cadence") for r in records):
            fail("no cadence in records")
        for key in ["avg_power", "max_power", "normalized_power", "avg_cadence"]:
            if not session.get(key):
                fail(f"session has no {key}")
        if session["normalized_power"] < session["avg_power"]:
            fail("normalised power below average power")
        if not all(l.get("avg_power") for l in laps):
            fail("a lap has no avg_power")
    elif any(r.get("power") for r in records):
        fail("unexpected power in records")

    timer_events = [(e.get("event"), e.get("event_type")) for e in messages["event_mesgs"]]

    print(f"OK {args.file}: {len(records)} records, {len(laps)} laps, "
          f"{session['total_distance']:.0f} m, timer {session['total_timer_time']:.0f} s, "
          f"elapsed {session['total_elapsed_time']:.0f} s")
    if args.power:
        print(f"   power: avg {session['avg_power']} W, NP {session['normalized_power']} W, "
              f"max {session['max_power']} W, cadence {session['avg_cadence']} rpm")
    print("   lap intensities:", [l.get("intensity") for l in laps])
    print("   lap triggers:   ", [l.get("lap_trigger") for l in laps])
    print("   timer events:   ", timer_events)


if __name__ == "__main__":
    main()
