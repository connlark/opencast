#!/usr/bin/env python3
"""Fake `xcodebuild` for run-ui-tests.sh self-tests.

Handles `test-without-building` by reading -resultBundlePath and the -only-testing:
identifiers, then writing a fixture result tree (<bundle>/tree.json) and exiting with a
code chosen by the MOCK_SCENARIO env var. `build-for-testing` is a no-op. This never
touches a simulator, so the tests exercise the wrapper's aggregation/verification logic
deterministically.
"""
import json
import os
import signal
import sys
import time


def parse(argv):
    bundle = None
    ids = []
    for a in argv:
        if a == "-resultBundlePath":
            bundle = argv[argv.index(a) + 1]
        elif a.startswith("-only-testing:"):
            ids.append(a.split("-only-testing:", 1)[1])
    return bundle, ids


def write_tree(bundle, ids, failing=None):
    failing = failing or set()
    nodes = []
    for ident in ids:
        comps = ident.split("/")
        leaf = {
            "nodeType": "Test Case",
            "name": comps[-1] + "()",
            "result": "Failed" if ident in failing else "Passed",
        }
        # nest as target/class/method so the extractor's last-3 rule yields `ident`
        node = leaf
        for name in reversed(comps[:-1]):
            node = {"nodeType": "Group", "name": name, "children": [node]}
        nodes.append({"nodeType": "Plan", "name": "OpenCast", "children": [node]})
    os.makedirs(bundle, exist_ok=True)
    with open(os.path.join(bundle, "tree.json"), "w") as f:
        json.dump({"testNodes": nodes}, f)


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit(0)
    action = argv[0]
    if action == "build-for-testing":
        sys.exit(0)
    if action != "test-without-building":
        sys.exit(0)

    bundle, ids = parse(argv)
    lane = os.path.basename(bundle).replace(".xcresult", "") if bundle else "?"
    scenario = os.environ.get("MOCK_SCENARIO", "pass")

    if scenario == "hang":
        # Terminate promptly when the wrapper signals us; simulates a lane in flight.
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        time.sleep(60)
        sys.exit(0)

    if scenario == "fail_shard2" and lane == "shard2":
        write_tree(bundle, ids, failing={ids[0]} if ids else set())
        sys.exit(65)

    if scenario == "incomplete_shard1" and lane == "shard1":
        # Exit 0 but leave no bundle at all -> wrapper must flag incomplete.
        sys.exit(0)

    if scenario == "missing_shard1" and lane == "shard1":
        write_tree(bundle, ids[1:])  # drop one assigned test
        sys.exit(0)

    write_tree(bundle, ids)
    sys.exit(0)


if __name__ == "__main__":
    main()
