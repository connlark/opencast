#!/usr/bin/env python3
"""Fail if a loaded credential or a recognisable key shape appears in artifacts.

Ported from the earlier cross-provider artifact scanner (stdlib). Every `--key-file` contributes its exact value; a JSON key file (the
Cloudflare one) contributes every string value except the non-secret
identifiers `account_id` and `gateway_id` (the account id appears in vendor
URLs by design). Patterns: `sk-` (OpenAI), `sk-ant-` (Anthropic), `AIza` and
`AQ.` (Google), `pplx-` (Perplexity). Writes `<root>/secret-scan.json` (no
secret values, only file names and match kinds) and exits 1 on any finding.

    python3 eval/secret_scan.py --root ROOT --key-file /path/key [--key-file ...]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re

# A key never starts mid-word ("task-...", "desk-..." are not keys); Perplexity
# keys are one alphanumeric run, so model names like pplx-decider-flash-latest
# never match.
PATTERNS = {
    "openai_key_pattern": re.compile(rb"(?<![A-Za-z0-9])sk-(?!ant-)[A-Za-z0-9_-]{16,}"),
    "anthropic_key_pattern": re.compile(rb"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{16,}"),
    "gemini_key_pattern": re.compile(rb"(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{20,}"),
    "google_aq_key_pattern": re.compile(rb"(?<![A-Za-z0-9])AQ\.[0-9A-Za-z_.-]{20,}"),
    "perplexity_key_pattern": re.compile(rb"(?<![A-Za-z0-9])pplx-[A-Za-z0-9]{24,}"),
}
PUBLIC_FIELDS = {"account_id", "gateway_id"}
MIN_SECRET_BYTES = 8
RECEIPT = "secret-scan.json"


def secret_values(path):
    """Exact secret byte strings from one key file (never returned to output)."""
    raw = path.read_bytes().strip()
    if not raw:
        raise SystemExit(f"secret scan key file is empty: {path.name}")
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        values = [
            v.strip().encode()
            for k, v in doc.items()
            if isinstance(v, str) and k not in PUBLIC_FIELDS and v.strip()
        ]
    else:
        values = [raw]
    for value in values:
        if len(value) < MIN_SECRET_BYTES:
            raise SystemExit(f"secret scan refuses a value shorter than {MIN_SECRET_BYTES} bytes in {path.name}")
    return values


def scan(root, key_files):
    exact = []
    for path in key_files:
        exact.extend((path.name, value) for value in secret_values(path))
    findings, scanned = [], 0
    for path in sorted(c for c in root.rglob("*") if c.is_file() and not c.is_symlink()):
        relative = str(path.relative_to(root))
        if relative == RECEIPT:
            continue
        data = path.read_bytes()
        scanned += 1
        for index, (name, secret) in enumerate(exact, start=1):
            if secret in data:
                findings.append({"file": relative, "match": f"exact_loaded_secret_{index}", "key_file": name})
        for name, pattern in PATTERNS.items():
            if pattern.search(data):
                findings.append({"file": relative, "match": name})
    receipt = {
        "schema_version": 2,
        "artifact_root": root.name,
        "files_scanned": scanned,
        "key_files": [p.name for p in key_files],
        "exact_loaded_secrets_checked": len(exact),
        "recognizable_patterns_checked": sorted(PATTERNS),
        "passed": not findings,
        "findings": findings,
    }
    (root / RECEIPT).write_text(json.dumps(receipt, indent=1) + "\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--key-file", type=pathlib.Path, action="append", required=True)
    args = parser.parse_args()
    receipt = scan(args.root, args.key_file)
    if receipt["findings"]:
        print("secret scan: FAIL")
        for finding in receipt["findings"]:
            print(f"  {finding['file']}: {finding['match']}")
        return 1
    print(f"secret scan: PASS ({receipt['files_scanned']} artifact files, "
          f"{receipt['exact_loaded_secrets_checked']} exact values)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
