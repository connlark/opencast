#!/usr/bin/env python3
"""Regenerate scripts/ui-test-shards.txt from a run directory produced by run-ui-tests.sh.

Balances the parallel-safe seeded OpenCastUITests iPhone tests across two shards by
measured per-test wall-clock (longest-processing-time greedy), keeps timing-sensitive
tests in a serial tail, and records opt-in/live/device tests as excluded so the runner's
--check guard can detect coverage drift.

    scripts/gen-ui-test-shards.py <run-dir>        # e.g. artifacts/ui-tests/run-YYYYMMDD-HHMMSS

Durations come from the shard/serial/fallback *.log files' "Test Case ... passed
(N seconds)" lines — NOT the .xcresult `duration` field, which reports 0.0s for several
screenshot-matrix tests (that bad data once piled ~10 min of hidden work into one shard).
The script errors if any routine test still resolves to 0s, so the trap can't recur.

Review the diff before committing; this never edits schemes or app code.
"""
import glob
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "OpenCastUITests" / "OpenCastUITests.swift"
MANIFEST = REPO / "scripts" / "ui-test-shards.txt"
PREFIX = "OpenCastUITests/OpenCastUITests/"

# Timing-sensitive tests that must run alone (no CPU contention from a sibling shard).
SERIAL_TAIL = {"testNowPlayingFramePacing"}

PASSED_RE = re.compile(
    r"Test Case '-\[OpenCastUITests\.OpenCastUITests (\w+)\]' passed \(([\d.]+) seconds\)"
)


def durations_from_logs(run_dir: str):
    durs = {}
    logs = glob.glob(os.path.join(run_dir, "*.log"))
    if not logs:
        sys.exit(f"No *.log files under {run_dir}; pass a run-ui-tests.sh output directory.")
    for log in logs:
        with open(log, errors="ignore") as f:
            for line in f:
                m = PASSED_RE.search(line)
                if m:
                    durs[m.group(1)] = float(m.group(2))
    return durs


def source_test_methods():
    text = SOURCE.read_text()
    return sorted(set(re.findall(r"func (test[A-Za-z0-9_]+)\(", text)))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run_dir = sys.argv[1]

    durs = durations_from_logs(run_dir)
    if not durs:
        sys.exit(f"No passed-test durations parsed from logs in {run_dir}")

    zero = sorted(nm for nm, s in durs.items() if s <= 0.0)
    if zero:
        sys.exit(
            "Refusing to balance: these routine tests resolved to 0s (unreliable timing "
            "data — rerun the suite and regenerate):\n  " + "\n  ".join(zero)
        )

    serial = sorted(nm for nm in durs if nm in SERIAL_TAIL)
    pool = sorted(((s, nm) for nm, s in durs.items() if nm not in SERIAL_TAIL), reverse=True)

    bins, load = [[], []], [0.0, 0.0]
    for s, nm in pool:  # longest-processing-time greedy
        i = 0 if load[0] <= load[1] else 1
        bins[i].append((s, nm))
        load[i] += s

    routine = set(durs)
    excluded = sorted(set(source_test_methods()) - routine)

    out = []
    out.append("# OpenCast UI-test shard manifest")
    out.append("# Consumed by scripts/run-ui-tests.sh. One entry per line: <lane> <test-identifier>")
    out.append("#")
    out.append("# Lanes:")
    out.append("#   shard1 / shard2  parallel-safe seeded iPhone tests, run concurrently on two sims")
    out.append("#   serial           timing-sensitive; runs alone after shards (no CPU contention)")
    out.append("#   exclude          opt-in/live/device/AirPlay tests NOT run in the routine iPhone lane")
    out.append("#")
    out.append("# Balanced by measured per-test wall-clock (log 'passed (N seconds)' lines), NOT the")
    out.append("# .xcresult duration field — that reports 0.0s for screenshot-matrix tests. Regenerate")
    out.append("# with scripts/gen-ui-test-shards.py <run-dir> after a fresh run.")
    out.append(
        f"# shard1 est {load[0]:.0f}s ({len(bins[0])} tests) | shard2 est {load[1]:.0f}s "
        f"({len(bins[1])} tests) | serial {sum(durs[n] for n in serial):.0f}s"
    )
    out.append("")
    for i, b in enumerate(bins):
        out.append(f"# --- shard{i + 1} (est {load[i]:.0f}s) ---")
        for _, nm in sorted(b, key=lambda x: x[1]):
            out.append(f"shard{i + 1} {PREFIX}{nm}")
        out.append("")
    out.append("# --- serial tail (timing-sensitive; runs alone) ---")
    for nm in serial:
        out.append(f"serial {PREFIX}{nm}")
    out.append("")
    out.append("# --- excluded from routine iPhone lane (opt-in / live / device / AirPlay) ---")
    for nm in excluded:
        out.append(f"exclude {PREFIX}{nm}")
    out.append("")

    MANIFEST.write_text("\n".join(out))
    print(
        f"wrote {MANIFEST.relative_to(REPO)}: "
        f"shard1={len(bins[0])} ({load[0]:.0f}s) shard2={len(bins[1])} ({load[1]:.0f}s) "
        f"serial={len(serial)} exclude={len(excluded)} skew={abs(load[0] - load[1]):.0f}s"
    )


if __name__ == "__main__":
    main()
