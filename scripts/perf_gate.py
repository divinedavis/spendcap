#!/usr/bin/env python3
"""Performance budget for every ship (2026-10-04, ported from Marracat). Reads the XCTMetric numbers
PerformanceTests left in an .xcresult and compares each one with its baseline in
scripts/perf_baseline.json.

The baseline follows the app instead of being a fixed number (owner: "these
should be dynamic as i build features and remove features"):
  * a new performance test or metric is recorded the first time it runs;
  * one whose test was removed drops out of the file;
  * each passing ship (--record) adds its median to that metric's last 5, and
    the baseline is the median of those, so a feature that honestly costs a
    little moves the bar after a few ships while a sudden 1.5x jump fails.

FAIL when a "prefers smaller" metric's median is more than TOLERANCE over its
baseline. The tolerance is wide on purpose: it is a simulator on a Mac that
other work shares, so it catches a doubling, not a 10% wobble.

  python3 scripts/perf_gate.py build.nosync/gates/Perf.xcresult [--record]
"""
import json, os, statistics, subprocess, sys

TOLERANCE = 0.5      # fail above baseline * 1.5
KEEP = 5             # passing ships remembered per metric
# A relative bar is meaningless on a tiny number: "Memory Physical" during a
# scroll is the GROWTH in kB, ~300-1,700 kB from run to run on one build
# (Marracat, 2026-10-03: 852 vs a 344 baseline failed while total memory had dropped
# 320 MB -> 183 MB). Memory must also be this many kB worse to fail.
MIN_KB_REGRESSION = 5000
HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "perf_baseline.json")


def read_metrics(xcresult):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", xcresult],
                         capture_output=True, text=True, check=True).stdout
    got = {}
    for t in json.loads(out):
        for run in t.get("testRuns", []):
            for m in run.get("metrics", []):
                if not m.get("measurements"):
                    continue
                key = f"{t['testIdentifier']} :: {m['displayName']}"
                got[key] = {"median": statistics.median(m["measurements"]), "unit": m.get("unitOfMeasurement", ""),
                            "smaller": m.get("polarity", "prefers smaller") == "prefers smaller"}
    return got


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    record = "--record" in sys.argv
    if not args:
        print(__doc__); return 2
    got = read_metrics(args[0])
    if not got:
        print("perf gate: no performance metrics in the result bundle — did PerformanceTests run?")
        return 1
    try:
        base = json.load(open(BASELINE))
    except FileNotFoundError:
        base = {}

    failed = []
    print(f"{'metric':<92} {'now':>9} {'baseline':>9}  verdict")
    for key, m in sorted(got.items()):
        hist = base.get(key, {}).get("history", [])
        if not hist:
            verdict, ref = "new (recorded)", None
        else:
            ref = statistics.median(hist)
            over = m["median"] > ref * (1 + TOLERANCE) if m["smaller"] else m["median"] < ref * (1 - TOLERANCE)
            if over and m["smaller"] and m["unit"] == "kB" and m["median"] - ref < MIN_KB_REGRESSION:
                over = False
            verdict = f"FAIL (>{int(TOLERANCE * 100)}% worse)" if over else "ok"
            if over:
                failed.append(key)
        print(f"{key:<92} {m['median']:>9.3f} {ref if ref is not None else float('nan'):>9.3f}  {verdict}  {m['unit']}")
    gone = sorted(set(base) - set(got))
    for key in gone:
        print(f"{key:<92} {'—':>9} {'':>9}  removed (test no longer exists)")

    if failed:
        print(f"perf gate FAILED: {len(failed)} metric(s) regressed. Profile it (Instruments > Time Profiler) before shipping.")
        return 1
    if record:
        new = {k: {"history": (base.get(k, {}).get("history", []) + [round(m["median"], 4)])[-KEEP:], "unit": m["unit"]}
               for k, m in got.items()}
        with open(BASELINE, "w") as f:
            json.dump(new, f, indent=2, sort_keys=True); f.write("\n")
        print(f"perf gate OK — baseline updated ({len(new)} metrics, {len(gone)} removed)")
    else:
        print("perf gate OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
