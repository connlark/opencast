#!/usr/bin/env python3
"""Generate deterministic, disk-backed partial-import performance cases.

Each incoming file has N closed items and a malformed tail. Replay each case
after its complete baseline, using the same canonical benchmark URL. Generated
files and manifests belong outside shipped resources.
"""
import argparse
import hashlib
import json
from pathlib import Path


def generate(directory, count, size):
    prefix = b'<rss><channel><title>OpenCast Partial Catalog Stress</title>'
    phrase = "Complete searchable historical detail. "

    def item(index, padding=0, duplicate=False):
        identity = index // 2 if duplicate else index
        namespace = "duplicate" if duplicate else "stress"
        guid = f"{namespace}-{identity:06d}"
        title = f"Historical {namespace} episode {identity:06d}"
        if identity in (0, count):
            guid += "x" * (512 * 1024)
            title += " long identity" * 8192
        notes = (phrase * (padding // len(phrase) + 1))[:padding]
        return (f'<item><guid>{guid}</guid><title>{title}</title>'
                '<pubDate>Sat, 05 Sep 2026 12:00:00 +0000</pubDate>'
                f'<enclosure url="https://example.com/{namespace}/{identity:06d}.mp3" type="audio/mpeg"/>'
                f'<description><![CDATA[{notes}]]></description></item>').encode()

    cases = {
        "baseline": (range(count), False, count),
        "all": (range(count), False, count),
        "none": (range(count, count * 2), False, count * 2),
        "mixed": (list(range(count // 2)) + list(range(count, count + count - count // 2)), False,
                  count + count - count // 2),
        "duplicates": (range(count), True, count + (count + 1) // 2),
    }
    manifests = []
    directory.mkdir(parents=True, exist_ok=True)
    for name, (indices, duplicates, expected) in cases.items():
        suffix = b'</channel></rss>' if name == "baseline" else b'<item><title>Interrupted tail'
        remaining = size - len(prefix) - len(suffix) - sum(len(item(i, duplicate=duplicates)) for i in indices)
        assert remaining >= 0, "Fixture byte target is too small"
        padding, extra = divmod(remaining, count)
        path = directory / f"partial-{count}-{name}.xml"
        digest = hashlib.sha256()
        with path.open("wb") as output:
            def write(data):
                output.write(data)
                digest.update(data)
            write(prefix)
            for offset, index in enumerate(indices):
                write(item(index, padding + (offset < extra), duplicates))
            write(suffix)
        assert path.stat().st_size == size
        manifests.append({"file": path.name, "case": name, "raw_closed_items": count,
                          "expected_cached_count": expected, "decoded_bytes": size,
                          "sha256": digest.hexdigest(), "complete": name == "baseline"})
    (directory / f"partial-{count}-manifest.json").write_text(json.dumps(manifests, indent=2) + "\n")
    print(json.dumps(manifests))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--items", type=int, choices=[13_753, 100_000], required=True)
    arguments = parser.parse_args()
    generate(arguments.output, arguments.items, 60_708_532 if arguments.items == 13_753 else 128 * 1024 * 1024)
