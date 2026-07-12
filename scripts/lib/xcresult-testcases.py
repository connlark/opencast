#!/usr/bin/env python3
"""Read an `xcresulttool get test-results tests` JSON tree on stdin and print one
line per executed test case as `<result>\\t<target/class/method>`.

Used by scripts/run-ui-tests.sh to verify each shard executed exactly its assigned
inventory with no failures. Kept as a tiny standalone filter so the runner has a
single, mockable xcresult seam (the tests feed it a fixture tree via a fake
xcresulttool).
"""
import json
import sys


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(2)

    def walk(node, path):
        name = node.get("name", "")
        comps = path + [name]
        if node.get("nodeType") == "Test Case":
            # Last three components are target/class/method; drop the () on the method
            # so the id matches the -only-testing identifiers in the shard manifest.
            ident = "/".join(comps[-3:]).replace("()", "")
            print(f"{node.get('result', '')}\t{ident}")
        for child in node.get("children", []):
            walk(child, comps)

    for tn in data.get("testNodes", []):
        walk(tn, [])


if __name__ == "__main__":
    main()
