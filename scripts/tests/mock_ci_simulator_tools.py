#!/usr/bin/env python3
"""Fake xcodebuild, simctl and xcresulttool for run-ci-simulator-tests.sh self-tests.

The first argument picks the tool. Every call is appended to $MOCK_CALLS, one line per
call, so the self-test can assert what ran and in which order.

`xcodebuild build-for-testing` writes a stub OpenCast.app under -derivedDataPath.
`xcodebuild test-without-building` plays the next outcome of $MOCK_SCENARIO (a
comma-separated list, one outcome per attempt) by writing <bundle>/summary.json and
exiting the way xcodebuild would. `xcresulttool` prints that summary. `simctl` succeeds
unless $MOCK_SIMCTL_FAIL names the subcommand. Nothing here touches a simulator.
"""
import json
import os
import plistlib
import sys

LAUNCH_TIMEOUT = (
    "Failed to launch <XCUIApplicationImpl: 0x0 example.opencast.mock at "
    "/tmp/OpenCast.app> via Xcode: Timed out while launching application via Xcode."
)
AX_TIMEOUT = (
    "The test runner failed to initialize for UI testing. "
    "(Underlying Error: Timed out waiting for AX loaded notification)"
)
ASSERTION = "Expectation failed: (count → 2) == 1"


def summary(total, failed, failures=()):
    return {
        "result": "Failed" if failed else "Passed",
        "totalTestCount": total,
        "passedTests": total - failed,
        "failedTests": failed,
        "skippedTests": 0,
        "expectedFailures": 0,
        "testFailures": [{"testName": f"test{index}()", "failureText": text}
                         for index, text in enumerate(failures)],
    }


OUTCOMES = {
    # name: (summary or None for "no bundle", exit code, extra log line)
    "pass": (summary(3, 0), 0, ""),
    "launch_timeout": (summary(1, 1, [LAUNCH_TIMEOUT]), 65, LAUNCH_TIMEOUT),
    "ax_timeout": (summary(0, 0), 65, AX_TIMEOUT),
    "no_bundle": (None, 70, "xcodebuild: error: testing failed before a result bundle existed"),
    "zero_tests": (summary(0, 0), 0, "Executed 0 tests, with 0 failures"),
    "real_failure": (summary(3, 1, [ASSERTION]), 65, ASSERTION),
    "mixed": (summary(3, 2, [LAUNCH_TIMEOUT, ASSERTION]), 65, ASSERTION),
}


def value_after(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv else None


def record(tool, argv):
    with open(os.environ["MOCK_CALLS"], "a", encoding="utf-8") as calls:
        calls.write(" ".join([tool, *argv]) + "\n")


def previous_test_calls():
    with open(os.environ["MOCK_CALLS"], encoding="utf-8") as calls:
        return sum(1 for line in calls if line.startswith("xcodebuild test-without-building"))


def xcodebuild(argv):
    action = argv[0] if argv else ""
    if action == "build-for-testing":
        record("xcodebuild", argv)
        if os.environ.get("MOCK_BUILD_FAILS") == "1":
            print("error: mock compile failure")
            sys.exit(65)
        app = os.path.join(value_after(argv, "-derivedDataPath"), "Build", "Products",
                           "Debug-iphonesimulator", "OpenCast.app")
        os.makedirs(app, exist_ok=True)
        with open(os.path.join(app, "Info.plist"), "wb") as plist:
            plistlib.dump({"CFBundleIdentifier": "example.opencast.mock"}, plist)
        sys.exit(0)
    if action != "test-without-building":
        sys.exit(0)

    attempt = previous_test_calls()
    record("xcodebuild", argv)
    outcomes = os.environ.get("MOCK_SCENARIO", "pass").split(",")
    result, code, line = OUTCOMES[outcomes[min(attempt, len(outcomes) - 1)]]
    if line:
        print(line)
    if result is not None:
        bundle = value_after(argv, "-resultBundlePath")
        os.makedirs(bundle, exist_ok=True)
        with open(os.path.join(bundle, "summary.json"), "w", encoding="utf-8") as output:
            json.dump(result, output)
    sys.exit(code)


def simctl(argv):
    record("simctl", argv)
    if argv and argv[0] in os.environ.get("MOCK_SIMCTL_FAIL", "").split(","):
        sys.exit(1)
    sys.exit(0)


def xcresulttool(argv):
    path = os.path.join(value_after(argv, "--path") or "", "summary.json")
    if not os.path.exists(path):
        sys.stderr.write("mock xcresulttool: no result data\n")
        sys.exit(1)
    with open(path, encoding="utf-8") as source:
        sys.stdout.write(source.read())


if __name__ == "__main__":
    {"xcodebuild": xcodebuild, "simctl": simctl, "xcresulttool": xcresulttool}[sys.argv[1]](sys.argv[2:])
