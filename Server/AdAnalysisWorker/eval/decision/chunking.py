"""Chunking over the request's segment ARRAY ORDER.

Segment ids are opaque labels (synthetic fixtures use sparse ids 10, 20, ...);
nothing here does arithmetic on an id. A chunk is a contiguous, inclusive range
of array indices `[first, last]`; chunks tile the array exactly, in order.

Specs:
* `{"kind": "segments", "size": N}` (id `segN`): N consecutive segments, the
  last chunk takes the remainder.
* `{"kind": "seconds", "size": S}` (id `secS`): pack consecutive segments while
  the chunk's span (last.end - first.start) stays <= S seconds; a segment that
  alone exceeds S is its own chunk. Packing never mixes a short ad segment into
  a long neighbour, which a "close once >= S" rule would.
* `{"kind": "segments", "size": 1}` (`seg1`) is the per-segment design (a).

Chunk designs are localisers, not boundary finders: a chunk overshoots or
undershoots a boundary by up to its own length, which is why the two-stage
design refines boundaries per segment.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Chunk:
    index: int
    first: int  # array index, inclusive
    last: int  # array index, inclusive
    start: float
    end: float

    @property
    def label(self):
        return f"C{self.index}"

    @property
    def duration(self):
        return self.end - self.start

    def as_dict(self):
        return {**asdict(self), "label": self.label}


def spec_id(spec):
    prefix = {"segments": "seg", "seconds": "sec"}[spec["kind"]]
    size = spec["size"]
    return f"{prefix}{int(size) if float(size).is_integer() else size}"


def parse_spec(text):
    """`seg10` / `sec30` -> spec dict."""
    if text.startswith("seg"):
        return {"kind": "segments", "size": int(text[3:])}
    if text.startswith("sec"):
        return {"kind": "seconds", "size": float(text[3:])}
    raise ValueError(f"Unknown chunking {text!r}")


def _chunk(segments, index, first, last):
    return Chunk(index, first, last, segments[first]["start"], segments[last]["end"])


def by_segments(segments, size):
    if size < 1:
        raise ValueError("Chunk size must be >= 1")
    return [
        _chunk(segments, k, first, min(first + size, len(segments)) - 1)
        for k, first in enumerate(range(0, len(segments), size))
    ]


def by_seconds(segments, seconds):
    if seconds <= 0:
        raise ValueError("Chunk seconds must be > 0")
    chunks = []
    first = 0
    for i in range(1, len(segments) + 1):
        if i == len(segments) or segments[i]["end"] - segments[first]["start"] > seconds:
            chunks.append(_chunk(segments, len(chunks), first, i - 1))
            first = i
    return chunks


def make(segments, spec):
    if not segments:
        return []
    if spec["kind"] == "segments":
        return by_segments(segments, int(spec["size"]))
    if spec["kind"] == "seconds":
        return by_seconds(segments, float(spec["size"]))
    raise ValueError(f"Unknown chunking kind {spec['kind']!r}")


def chunk_of(chunks):
    """Array index -> chunk index."""
    owner = {}
    for chunk in chunks:
        for i in range(chunk.first, chunk.last + 1):
            owner[i] = chunk.index
    return owner


def check_tiling(chunks, count):
    """Chunks tile [0, count) exactly, in order (the structural invariant)."""
    expected = 0
    for k, chunk in enumerate(chunks):
        if chunk.index != k or chunk.first != expected or chunk.last < chunk.first:
            raise ValueError("Chunks do not tile the segment array")
        expected = chunk.last + 1
    if expected != count:
        raise ValueError("Chunks do not cover every segment")


def region(chunks, a, b):
    """Array-index range covered by chunks a..b, clamped to the chunk list."""
    a = max(0, a)
    b = min(len(chunks) - 1, b)
    return chunks[a].first, chunks[b].last
