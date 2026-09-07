#!/usr/bin/env python3
"""Run generated partial feeds on a connected device using the installed Release probe.

Only the designated synthetic benchmark cache is reset. Run outside the default
workspace sandbox, like other Xcode/device commands. Reports and fixtures stay
outside the repository and shipped app resources.
"""
import argparse
import json
import pathlib
import subprocess
import time

BUNDLE_ID = "com.connor.opencast"
CANONICAL_URL = "https://example.com/opencast-stress-100000.xml"
FIXTURE_DIRECTORY = "Library/Application Support/OpenCastFeedFixtures/"
REPORT_DIRECTORY = "Library/Application Support/OpenCastFeedBenchmark/"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    parser.add_argument("--reports", type=pathlib.Path, required=True)
    options = parser.parse_args()
    options.reports.mkdir(parents=True, exist_ok=True)
    results = []
    copied = set()
    run_id = str(int(time.time()))

    def command(arguments, log):
        with (options.reports / log).open("w") as output:
            return subprocess.run(
                ["xcrun", "devicectl", *arguments], stdout=output,
                stderr=subprocess.STDOUT, timeout=180,
            ).returncode

    def copy(direction, source, destination, log):
        return command([
            "device", "copy", direction, "--device", options.device,
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
            "--source", str(source), "--destination", str(destination),
        ], log)

    def benchmark(count, case, label):
        filename = f"partial-{count}-{case}.xml"
        if filename not in copied:
            for attempt in range(3):
                status = copy("to", options.fixtures / filename,
                              FIXTURE_DIRECTORY + filename, label + "-copy.log")
                if status == 0:
                    break
                if attempt < 2:
                    time.sleep(3)
            assert status == 0, ("copy", filename)
            copied.add(filename)

        arguments = [
            "device", "process", "launch", "--device", options.device,
            "--terminate-existing", BUNDLE_ID, "--opencast-run-feed-benchmark",
            "--opencast-feed-benchmark-file", filename,
            "--opencast-feed-benchmark-label", label,
            "--opencast-feed-benchmark-url", CANONICAL_URL,
        ]
        if case == "baseline":
            arguments.append("--opencast-feed-benchmark-reset-synthetic")
        assert command(arguments, label + "-launch.log") == 0, ("launch", label)
        deadline = time.monotonic() + 300
        report_path = options.reports / (label + ".json")
        while time.monotonic() < deadline:
            time.sleep(3)
            status = copy("from", REPORT_DIRECTORY + label + ".json",
                          report_path, label + "-report-copy.log")
            if status != 0 or not report_path.exists():
                continue
            report = json.loads(report_path.read_text())
            assert report["phase"] != "failed", report
            if report["phase"] != "complete":
                continue
            report.update(case=case, matrixCount=count)
            results.append(report)
            (options.reports / "partial-results.json").write_text(json.dumps(results, indent=2))
            incremental_bytes = report["sampledPeakBytes"] - report["footprintStartBytes"]
            print(json.dumps({
                "label": label, "case": case, "cached": report["cachedCount"],
                "prepared": report["episodeCount"], "seconds": report["processingSeconds"],
                "incrementalMiB": incremental_bytes / 1_048_576,
                "mainActorMS": report["maximumMainActorDelaySeconds"] * 1000,
            }), flush=True)
            manifests = json.loads((options.fixtures / f"partial-{count}-manifest.json").read_text())
            manifest = next(item for item in manifests if item["case"] == case)
            assert report["bodyHash"] == manifest["sha256"], ("fixture hash", report)
            assert report["cachedCount"] == manifest["expected_cached_count"], ("count", report)
            assert ("complete" in report["completeness"]) == manifest["complete"], ("completeness", report)
            assert report["processingSeconds"] <= (30 if count == 13_753 else 90), ("processing time", report)
            assert incremental_bytes <= (150 if count == 13_753 else 256) * 1_048_576, ("memory", report)
            assert report["maximumMainActorDelaySeconds"] <= 0.250, ("main actor", report)
            return
        raise TimeoutError(label)

    for count in [13_753, 100_000]:
        for case in ["all", "none", "mixed", "duplicates"]:
            print(f"Starting {count} {case}", flush=True)
            benchmark(count, "baseline", f"partial-{run_id}-{count}-{case}-baseline")
            benchmark(count, case, f"partial-{run_id}-{count}-{case}")
    benchmark(100_000, "baseline", f"partial-{run_id}-restore-complete")
    print("ALL PARTIAL DEVICE GATES PASSED", flush=True)


if __name__ == "__main__":
    main()
