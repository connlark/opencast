#!/usr/bin/env python3
"""Fake `xcresulttool` for run-ui-tests.sh self-tests.

Supports `get test-results tests --path <bundle>` by printing the fixture tree that
mock_xcodebuild wrote at <bundle>/tree.json. Exits nonzero if the tree is absent, so the
wrapper treats a missing/partial bundle as an incomplete result.
"""
import os
import sys


def main():
    argv = sys.argv[1:]
    if "--path" not in argv:
        sys.exit(1)
    bundle = argv[argv.index("--path") + 1]
    tree = os.path.join(bundle, "tree.json")
    if not os.path.exists(tree):
        sys.stderr.write("mock xcresulttool: no result data\n")
        sys.exit(1)
    with open(tree) as f:
        sys.stdout.write(f.read())


if __name__ == "__main__":
    main()
