#!/usr/bin/env python3
"""Generate the parity goldens for the OpenCastAnalysis tests.

Every case is built from original synthetic text (the ad-analysis eval
harness's synthetic fixtures plus generated transcripts), so the output is
safe to commit. Each case is replayed through the analysis services' eval
bridges and the bridge output is stored as the expected value;
`ParityGoldenTests` replays the same inputs through the Swift pipeline and
requires equality. Regenerate after any change to either side:

    cargo build --locked --example eval_bridge   # in both analysis workers
    python3 Packages/OpenCastAnalysis/scripts/generate-parity-goldens.py
"""

import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
AD_BRIDGE = REPO / "Server/AdAnalysisWorker/target/debug/examples/eval_bridge"
CHAPTERS_BRIDGE = REPO / "Server/TranscriptAnalysisWorker/target/debug/examples/eval_bridge"
FIXTURES = REPO / "Server/AdAnalysisWorker/eval/fixtures"
OUT = REPO / "Packages/OpenCastAnalysis/Tests/OpenCastAnalysisTests/Fixtures/parity-goldens.json"
CHAR_CLASSES = REPO / "Packages/OpenCastAnalysis/Tests/OpenCastAnalysisTests/Fixtures/rust-char-classes.json"
CHAR_TABLES = REPO / "Packages/OpenCastAnalysis/Sources/OpenCastAnalysis/Text/RustCharacterTables.swift"
POLICY_REVISION = "2026-10-20.2-medium-timeout"
AD_MODEL = "gemini-3.8-flash"
CHAPTERS_MODEL = "gemini-3.5-flash"

SENTENCES = [
    "The tide charts were pinned above the workbench all winter.",
    "We sanded the transom twice before the primer would hold.",
    "A neighbor brought over a hand plane older than the boat.",
    "The keel bolts came out with less trouble than we feared.",
    "Every seam was traced with chalk so we could find it again.",
    "Our sponsor today is Harbor Rope, braided line for any deck.",
    "Use code WORKBENCH for ten percent off your first order.",
    "Thanks to Harbor Rope for supporting the show this week.",
]


def bridge(executable, command):
    run = subprocess.run([str(executable)], input=json.dumps(command), text=True,
                         capture_output=True, check=True)
    return json.loads(run.stdout)


def gemini_body(answer=None, *, text=None, finish="STOP", usage=(1200, 300, 500), parts=None, candidates=1):
    content = {"parts": parts if parts is not None else [{"text": text if text is not None else json.dumps(answer)}]}
    body = {"candidates": [{"content": content, "finishReason": finish}] * candidates,
            "usageMetadata": {"promptTokenCount": usage[0], "candidatesTokenCount": usage[1],
                              "thoughtsTokenCount": usage[2], "totalTokenCount": sum(usage)}}
    if finish is None:
        del body["candidates"][0]["finishReason"]
    return json.dumps(body)


def span(kind, start, end, start_quote, end_quote, evidence, confidence=0.9, label="constructed break"):
    return {"kind": kind, "label": label, "start_segment_id": start, "end_segment_id": end,
            "confidence": confidence, "evidence_quote": evidence, "start_quote": start_quote,
            "end_quote": end_quote}


def carousel():
    return json.loads((FIXTURES / "promo-carousel.json").read_text())


def paid_feed():
    return json.loads((FIXTURES / "paid-feed-and-ad-session.json").read_text())


def long_transcript(count=1800, seconds=3.0):
    segments = [{"id": index, "start": index * seconds, "end": (index + 1) * seconds - 0.25,
                 "text": f"{SENTENCES[index % len(SENTENCES)]} Part {index}."} for index in range(count)]
    return {
        "schema_version": 1, "request_id": "synthetic-long", "episode_id": "synthetic-long-episode",
        "podcast_id": "synthetic-workbench", "episode_title": "Restoring the dinghy",
        "podcast_title": "Workbench Conversations",
        "transcript": {"language_code": "en", "audio_duration": count * seconds,
                       "fingerprint": "synthetic-long-v1", "updated_at": "2026-10-23T00:00:00Z",
                       "state": "completed", "segment_count": count},
        "segments": segments,
    }


def whole(request, first, last, confidence=0.9, kind="host_read_ad"):
    """A span whose receipts are the first and last words of its edges."""
    by_id = {s["id"]: s for s in request["segments"]}
    start_words = by_id[first]["text"].split()[:6]
    end_words = by_id[last]["text"].split()[-6:]
    return span(kind, first, last, " ".join(start_words), " ".join(end_words),
                " ".join(start_words[:3]), confidence)


CAROUSEL_VALID = [
    span("house_or_network_promo", 20, 50, "I'm Mira, and this is Harbor Letters",
         "Subscribe to Backstage Supper wherever you get podcasts",
         "Listen to Harbor Letters on your favorite podcast app", 0.95, "Two show trailers"),
    span("house_or_network_promo", 80, 100, "I'm Mira, and this is Harbor Letters",
         "discover the stories the harbor kept", "Listen to Harbor Letters", 0.9, "Harbor Letters trailer"),
    span("house_or_network_promo", 120, 120, "Try our sister show, Five Minute Gardens",
         "Subscribe wherever you listen to podcasts", "Five Minute Gardens", 0.85, "Sister show promo"),
]


def with_edit(spans, index, **changes):
    edited = [dict(s) for s in spans]
    edited[index].update(changes)
    return edited


def ad_cases():
    c = carousel()
    p = paid_feed()
    long = long_transcript()
    valid = {"spans": CAROUSEL_VALID}
    mismatch = {"spans": with_edit(CAROUSEL_VALID, 1, start_quote="a word from our sponsors")}
    # 32 spans whose compact text sits just under the 100,000-byte answer
    # cap; quoting it back re-serializes each integer confidence as 1.0 and
    # pushes the previous answer over the cap, so the repair cannot be built.
    oversized_spans = []
    for index in range(32):
        oversized_spans.append({"confidence": 1, "end_quote": "x", "end_segment_id": 50,
                                "evidence_quote": "harbor " * 380, "kind": "inserted_ad",
                                "label": "l" * 200, "start_quote": "y", "start_segment_id": 20})
    oversized_text = json.dumps({"spans": oversized_spans}, separators=(",", ":"))
    while len(oversized_text.encode()) < 99_990:
        oversized_spans[0]["label"] += "l"
        oversized_text = json.dumps({"spans": oversized_spans}, separators=(",", ":"))
    declared = json.loads(json.dumps(c))
    declared["transcript"]["declared_duration"] = 600.0
    budget = {"spans": [whole(c, 10, 10), whole(c, 60, 70), whole(c, 110, 110)]}
    # Canonically equivalent but byte-different spellings: a precomposed
    # Hangul syllable in the transcript, its jamo sequence in the receipts.
    hangul = json.loads(json.dumps(c))
    hangul["request_id"] = "synthetic-carousel-hangul"
    hangul["segments"][0]["text"] = "\uac00 offer now"
    hangul_span = span("inserted_ad", 10, 10, "\u1100\u1161", "now", "\u1100\u1161 offer", 0.9)
    # A private-use scalar some platforms call alphabetic and Rust does not.
    private_use = json.loads(json.dumps(c))
    private_use["request_id"] = "synthetic-carousel-private-use"
    private_use["segments"][0]["text"] = "\uf882 offer now"
    private_use_span = span("inserted_ad", 10, 10, "\uf882", "now", "offer now", 0.9)
    # An ignored field whose object key holds an unpaired surrogate escape.
    unpaired_key = gemini_body(valid)[:-1] + ',"extra":{"\\ud800":0}}'
    long_windows = {
        # Window 0 covers ids 0-799, window 1 680-1479, window 2 1360-1799.
        "window-0": {"spans": [whole(long, 5, 9, 0.95), whole(long, 700, 705, 0.95)]},
        "window-1": {"spans": [whole(long, 700, 705, 0.95), whole(long, 703, 712, 0.95), whole(long, 1000, 1004)]},
        "window-2": {"spans": [whole(long, 1700, 1702, 0.6)]},
    }
    long_budget = {f"window-{w}": {"spans": [whole(long, base + 10, base + 190), whole(long, base + 220, base + 400)]}
                   for w, base in ((0, 0), (1, 680), (2, 1360))}
    cases = [
        ("ads-valid", c, {"window-0": gemini_body(valid)}),
        ("ads-normalized-answer", c, {"window-0": ("answer", valid)}),
        ("ads-repair-valid", c, {"window-0": gemini_body(mismatch), "repair-0": gemini_body(valid)}),
        ("ads-repair-drops-candidate", c, {"window-0": gemini_body(mismatch),
                                           "repair-0": gemini_body({"spans": [CAROUSEL_VALID[0], CAROUSEL_VALID[2]]})}),
        ("ads-repair-malformed", c, {"window-0": gemini_body(mismatch), "repair-0": gemini_body(text="{\"spans\": [")}),
        ("ads-repair-still-invalid", c, {"window-0": gemini_body(mismatch), "repair-0": gemini_body(mismatch)}),
        ("ads-missing-repair", c, {"window-0": gemini_body(mismatch)}),
        ("ads-evidence-mismatch", c, {"window-0": gemini_body({"spans": with_edit(CAROUSEL_VALID, 0, evidence_quote="a fresh brush")})}),
        ("ads-invalid-kind", c, {"window-0": gemini_body({"spans": with_edit(CAROUSEL_VALID, 0, kind="sponsor_read")})}),
        ("ads-unknown-boundary", c, {"window-0": gemini_body({"spans": with_edit(CAROUSEL_VALID, 2, end_segment_id=999)})}),
        ("ads-invalid-span", c, {"window-0": gemini_body({"spans": with_edit(CAROUSEL_VALID, 1, confidence=1.5)})}),
        ("ads-blank-label", c, {"window-0": gemini_body({"spans": with_edit(CAROUSEL_VALID, 1, label="  ")})}),
        ("ads-break-duration", c, {"window-0": gemini_body({"spans": [span(
            "inserted_ad", 10, 110, "Welcome to Workbench Conversations", "Goodbye", "Harbor Letters")]})}),
        ("ads-mixed-unresolvable", c, {"window-0": gemini_body({"spans": [span(
            "host_read_ad", 10, 10, "Today we are repairing a wooden boat", "the old oil finish",
            "Inspect each plank")]})}),
        ("ads-long-boundary-trimmed", c, {"window-0": gemini_body({"spans": [span(
            "house_or_network_promo", 10, 50, "We'll compare it with the old oil finish after a short break",
            "Subscribe to Backstage Supper wherever you get podcasts", "Listen to Harbor Letters")]})}),
        ("ads-short-mixed-included", c, {"window-0": gemini_body({"spans": with_edit(
            CAROUSEL_VALID, 2, start_quote="Five Minute Gardens")})}),
        ("ads-budget-exceeded", c, {"window-0": gemini_body(budget)}),
        ("ads-declared-duration-budget", declared, {"window-0": gemini_body(budget)}),
        ("ads-merged-break-duration", c, {"window-0": gemini_body({"spans": [whole(c, 10, 60), whole(c, 70, 110)]})}),
        ("ads-covers-request", p, {"window-0": gemini_body({"spans": [whole(p, 10, 190)]})}),
        ("ads-merged-covers-request", p, {"window-0": gemini_body({"spans": [whole(p, 10, 90), whole(p, 100, 190)]})}),
        ("ads-too-many-breaks", c, {"window-0": gemini_body({"spans": [CAROUSEL_VALID[0]] * 33})}),
        ("ads-malformed-response", c, {"window-0": gemini_body(valid)[:120], "repair-0": gemini_body(valid)}),
        ("ads-candidate-count", c, {"window-0": gemini_body(valid, candidates=2)}),
        ("ads-two-answer-texts", c, {"window-0": gemini_body(parts=[{"text": json.dumps(valid)}, {"text": "{}"}])}),
        ("ads-thought-part-ignored", c, {"window-0": gemini_body(parts=[{"text": "thinking", "thought": True},
                                                                        {"text": json.dumps(valid)}])}),
        ("ads-unknown-answer-field", c, {"window-0": gemini_body({**valid, "note": "x"})}),
        ("ads-float-segment-id", c, {"window-0": gemini_body(text=json.dumps(valid).replace('"start_segment_id": 20', '"start_segment_id": 20.0', 1))}),
        ("ads-max-tokens", c, {"window-0": gemini_body(valid, finish="MAX_TOKENS")}),
        ("ads-no-finish-reason", c, {"window-0": gemini_body(valid, finish=None)}),
        ("ads-empty-answer", c, {"window-0": gemini_body({"spans": []})}),
        ("ads-repair-feedback-exceeded", c, {"window-0": gemini_body(text=oversized_text)}),
        ("ads-canonically-equivalent-receipt", hangul, {"window-0": gemini_body({"spans": [hangul_span]})}),
        ("ads-ignored-unpaired-key", c, {"window-0": unpaired_key}),
        ("ads-private-use-receipt", private_use, {"window-0": gemini_body({"spans": [private_use_span]})}),
        ("ads-multi-window", long, {k: gemini_body(v) for k, v in long_windows.items()}),
        ("ads-multi-window-failure", long, {"window-0": gemini_body(long_windows["window-0"]),
                                            "window-1": gemini_body({"spans": with_edit(long_windows["window-1"]["spans"], 2, start_quote="no such words")}),
                                            "window-2": gemini_body(long_windows["window-2"])}),
        ("ads-multi-window-budget", long, {k: gemini_body(v) for k, v in long_budget.items()}),
    ]
    out = []
    for name, request, replies in cases:
        rust_replies, swift_replies = {}, {}
        for key, value in replies.items():
            if isinstance(value, tuple):
                answer = value[1]
                rust_replies[key] = gemini_body(answer)
                swift_replies[key] = {"answer": {"texts": [json.dumps(answer)], "finish_reason": "STOP",
                                                 "usage": {"prompt_token_count": 1200, "candidates_token_count": 300,
                                                           "thoughts_token_count": 500, "total_token_count": 2000}}}
            else:
                rust_replies[key] = value
                swift_replies[key] = {"body": value}
        expected = bridge(AD_BRIDGE, {"op": "replay", "request": request, "thinking": "medium", "model": AD_MODEL,
                                      "policy_revision": POLICY_REVISION, "replies": rust_replies})
        out.append({"name": name, "feature": "ads", "command": "run", "request": request,
                    "replies": swift_replies, "model": AD_MODEL, "thinking": "medium", "expected": expected})
    # Repair preservation is a fixed contract: a four-word cue stays
    # locatable however tightly a policy caps new evidence quotes.
    before = {"spans": [CAROUSEL_VALID[0]]}
    shrunk = {"spans": [span("house_or_network_promo", 20, 20, "I'm Mira, and this is Harbor Letters",
                             "the boat disappeared", "a new documentary podcast", 0.95)]}
    out.append({"name": "ads-preserves-tight-evidence-policy", "feature": "ads", "command": "preserves",
                "request": c, "before": before, "after": shrunk, "evidence_words": 2,
                "expected": bridge(AD_BRIDGE, {"op": "preserves", "request": c, "before": before, "after": shrunk})})
    # The whole-episode span ceiling follows the services' 800/120 windows
    # even when a policy cuts smaller windows.
    medium = long_transcript(count=400)
    medium["request_id"] = "synthetic-medium"
    many = {"spans": [whole(medium, index * 3, index * 3) for index in range(33)]}
    out.append({"name": "ads-span-ceiling-small-windows", "feature": "ads", "command": "validate",
                "request": medium, "output": many, "window_segments": 200, "window_overlap": 60,
                "expected": bridge(AD_BRIDGE, {"op": "validate", "policy": "promo_ad_breaks_v3",
                                               "request": medium, "output": many})})
    render = bridge(AD_BRIDGE, {"op": "prepare", "policy": "promo_ad_breaks_v3", "request": long, "thinking": "low"})
    out.append({"name": "ads-render-long-low", "feature": "ads", "command": "render", "request": long,
                "model": AD_MODEL, "thinking": "low",
                "expected": {"windows": [{"index": i, "payload": w["payload"]} for i, w in enumerate(render["windows"])]}})
    return out


def chapters_request(count=40, seconds=30.0, gap=0.0, text=None):
    segments = []
    for index in range(count):
        start = index * (seconds + gap)
        segments.append({"id": index, "start": start, "end": start + seconds,
                         "text": text(index) if text else f"{SENTENCES[index % 5]} Note {index}."})
    duration = segments[-1]["end"] + 1
    return {
        "schema_version": 1, "request_id": f"synthetic-chapters-{count}", "episode_id": "synthetic-episode",
        "podcast_id": "synthetic-workbench", "episode_title": "Restoring the dinghy",
        "podcast_title": "Workbench Conversations",
        "transcript": {"language_code": "en-US", "audio_duration": duration,
                       "fingerprint": f"synthetic-chapters-{count}", "updated_at": "2026-10-23T00:00:00Z",
                       "state": "completed", "segment_count": count},
        "segments": segments,
    }


def chapter(title, start, end, confidence=0.9):
    return {"title": title, "start_segment_id": start, "end_segment_id": end, "confidence": confidence}


def summary(text="Two hosts restore a small wooden boat over one winter.", line="A winter of boat repair",
            claims=None):
    return {"summary": text, "one_line_description": line,
            "claims": claims if claims is not None else [
                {"text": "The hosts sanded the transom twice.", "evidence_segment_id": 1},
                {"text": "A neighbor lent them a hand plane.", "evidence_segment_id": 2},
                {"text": "The keel bolts came out easily.", "evidence_segment_id": 3}]}


def chapters_cases():
    small = chapters_request()
    valid = {"chapters": [chapter("Planning the restoration", 0, 12), chapter("Stripping the hull", 13, 26),
                          chapter("Reassembly and sea trial", 27, 39)], "summary": summary()}
    soft = {"chapters": [chapter("Planning the restoration of a very old and much loved wooden dinghy hull", 0, 12),
                         chapter("One two three four five six seven eight nine ten eleven twelve thirteen", 15, 26),
                         chapter("Reassembly ⛵ and #seatrial", 27, 38)],
            "summary": summary(text="Two hosts restore a boat.\nIt takes a winter.",
                               claims=[{"text": "c" * 230, "evidence_segment_id": 1}]), "extra": True}
    hard = {"chapters": [chapter("", 0, 12, 1.2), chapter("Overlap", 10, 20), chapter("Backwards", 30, 25),
                         chapter("Unknown", 99, 39)],
            "summary": summary(text="See www.example.com for more", claims=[])}
    count_cap = {"chapters": [chapter(f"Part {i}", i * 6, i * 6 + 5) for i in range(6)] + [chapter("End", 36, 39)],
                 "summary": summary()}
    long_summary = {"chapters": valid["chapters"], "summary": summary(text="w " * 700, line="l" * 141,
                                                                     claims=[{"text": " ", "evidence_segment_id": 77}] * 13)}
    invalid_id = {"chapters": [chapter("Planning", 0, 12), chapter("Stripping", 13, 26), chapter("End", 27, 600)],
                  "summary": summary()}
    dense = chapters_request(count=1500, seconds=1.0, text=lambda i: f"word {i}")
    units = bridge(CHAPTERS_BRIDGE, {"op": "render", "request": dense})
    unit_count = len(units["remap"])
    dense_valid = {"chapters": [chapter("Opening", 0, 99), chapter("Middle", 100, 199), chapter("Close", 200, unit_count - 1)],
                   "summary": summary(claims=[{"text": "A", "evidence_segment_id": 0},
                                              {"text": "B", "evidence_segment_id": 150},
                                              {"text": "C", "evidence_segment_id": unit_count - 1}])}
    dense_raw_ids = {"chapters": [chapter("Opening", 0, 99), chapter("Rest", 100, 1499)], "summary": summary()}
    too_long = chapters_request(count=2401, seconds=1.0, gap=2.0, text=lambda i: f"w{i}")
    cases = [
        ("chapters-valid", small, [gemini_body(valid)]),
        ("chapters-normalized-answer", small, [("answer", valid)]),
        ("chapters-soft-warnings", small, [gemini_body(soft)]),
        ("chapters-hard-violations", small, [gemini_body(hard), gemini_body(hard), gemini_body(hard)]),
        ("chapters-count-cap", small, [gemini_body(count_cap)]),
        ("chapters-text-limits", small, [gemini_body(long_summary)]),
        ("chapters-escalation", small, [gemini_body(invalid_id), gemini_body(text="not json"), gemini_body(valid)]),
        ("chapters-truncated", small, [gemini_body(valid, finish="MAX_TOKENS")] * 3),
        ("chapters-safety", small, [gemini_body(valid, finish="SAFETY")] * 3),
        # A Kelvin sign is canonically equivalent to K but not the same bytes.
        ("chapters-kelvin-finish-reason", small, [gemini_body(valid, finish="MAX_TO\u212aENS")] * 3),
        ("chapters-missing-attempt", small, [gemini_body(invalid_id)]),
        ("chapters-float-id", small, [gemini_body(text=json.dumps(valid).replace('"end_segment_id": 12', '"end_segment_id": 12.0', 1)), gemini_body(valid)]),
        ("chapters-no-candidates", small, [json.dumps({"candidates": []}), gemini_body(valid)]),
        ("chapters-empty-text", small, [gemini_body(text="  "), gemini_body(valid)]),
        ("chapters-malformed-body", small, ["{\"candidates\": [", gemini_body(valid)]),
        ("chapters-coalesced-valid", dense, [gemini_body(dense_valid)]),
        ("chapters-coalesced-raw-ids", dense, [gemini_body(dense_raw_ids), gemini_body(dense_valid)]),
        ("chapters-too-long", too_long, [gemini_body(valid)]),
    ]
    out = []
    for name, request, replies in cases:
        rust_replies, swift_replies = [], {}
        for index, value in enumerate(replies):
            if isinstance(value, tuple):
                rust_replies.append(gemini_body(value[1]))
                swift_replies[f"attempt-{index}"] = {"answer": {
                    "texts": [json.dumps(value[1])], "finish_reason": "STOP",
                    "usage": {"prompt_token_count": 1200, "candidates_token_count": 300,
                              "thoughts_token_count": 500, "total_token_count": 2000}}}
            else:
                rust_replies.append(value)
                swift_replies[f"attempt-{index}"] = {"body": value}
        expected = bridge(CHAPTERS_BRIDGE, {"op": "run", "request": request, "model": CHAPTERS_MODEL,
                                            "replies": rust_replies})
        out.append({"name": name, "feature": "chapters", "command": "run", "request": request,
                    "replies": swift_replies, "model": CHAPTERS_MODEL, "expected": expected})
        if name in ("chapters-valid", "chapters-coalesced-valid", "chapters-soft-warnings", "chapters-hard-violations"):
            out.append({"name": name + "-validate", "feature": "chapters", "command": "validate", "request": request,
                        "reply": {"body": rust_replies[0]}, "model": CHAPTERS_MODEL,
                        "expected": bridge(CHAPTERS_BRIDGE, {"op": "validate", "request": request,
                                                             "body": rust_replies[0]})})
    for name, request in (("chapters-render-small", small), ("chapters-render-dense", dense),
                          ("chapters-render-too-long", too_long)):
        out.append({"name": name, "feature": "chapters", "command": "render", "request": request,
                    "model": CHAPTERS_MODEL, "expected": bridge(CHAPTERS_BRIDGE, {"op": "render", "request": request})})
    return out


# Nesting: `serde_json` fails a typed read at the 128th nested container and
# reads an ignored one at any depth. A case's depth is the nesting level of
# the deepest container in the document parsed (the provider body, or the
# answer in its text part; the root is level 1). Past the boundary, cases
# nest 4,096, 65,536 and 1,048,576 levels (4 KiB, 64 KiB and 1 MiB of `[`).
# Large bodies are stored as pieces, `[[text, count], ...]`, concatenated in
# order.
NESTING_DEPTHS = (127, 128, 129)
NESTING_SIZES = (4 * 1024, 64 * 1024, 1024 * 1024)
NEST = "\u0001"


def pieces(template, levels, closed=True):
    """`template` with NEST replaced by `levels` opening brackets, and as
    many closing ones when closed."""
    head, tail = template.split(NEST)
    return [[head, 1], ["[", levels], ["]", levels if closed else 0], [tail, 1]]


def expand(body):
    return body if isinstance(body, str) else "".join(text * count for text, count in body["pieces"])


def nesting_templates(ad_answer, chapters_answer):
    """(name, feature, containers around NEST, body template): the two parses
    the services make (the provider body, the answer in its text part), each
    with the nesting in an ignored member and in typed positions."""
    def body(text):
        # NEST inside the answer text is escaped by the encoder; unescape it.
        return gemini_body(text=text).replace(json.dumps(NEST)[1:-1], NEST)
    ad_text = json.dumps(ad_answer)
    chapters_text = json.dumps(chapters_answer)
    summary_text = json.dumps(chapters_answer["summary"])
    templates = []
    for feature, text in (("ads", ad_text), ("chapters", chapters_text)):
        templates += [
            (f"{feature}-body-ignored-member", feature, 1, gemini_body(text=text)[:-1] + ', "nested": ' + NEST + "}"),
            (f"{feature}-body-root", feature, 0, NEST),
            (f"{feature}-body-candidates", feature, 1, '{"candidates": ' + NEST + "}"),
        ]
    templates += [
        ("ads-answer-unknown-member", "ads", 1, body(ad_text[:-1] + ', "nested": ' + NEST + "}")),
        ("ads-answer-root", "ads", 0, body(NEST)),
        ("ads-answer-spans", "ads", 1, body('{"spans": ' + NEST + "}")),
        ("chapters-answer-ignored-member", "chapters", 1, body(chapters_text[:-1] + ', "nested": ' + NEST + "}")),
        ("chapters-answer-root", "chapters", 0, body(NEST)),
        ("chapters-answer-chapters", "chapters", 1, body('{"chapters": ' + NEST + ', "summary": ' + summary_text + "}")),
    ]
    return templates


def nesting_cases():
    """Each template at depths 127, 128 and 129 and nested 4,096, 65,536 and
    1,048,576 levels, closed and unclosed, through the ad bridge's `parse` op or
    the chapters bridge's `validate` op; plus whole runs at the boundary."""
    c = carousel()
    small = chapters_request()
    ad_answer = {"spans": CAROUSEL_VALID}
    chapters_answer = {"chapters": [chapter("Planning the restoration", 0, 12), chapter("Stripping the hull", 13, 26),
                                    chapter("Reassembly and sea trial", 27, 39)], "summary": summary()}
    out = []
    for name, feature, around, template in nesting_templates(ad_answer, chapters_answer):
        shapes = [(f"depth-{depth}", depth - around, True) for depth in NESTING_DEPTHS]
        shapes += [(f"{size}-levels-{'closed' if closed else 'unclosed'}", size, closed)
                   for size in NESTING_SIZES for closed in (True, False)]
        for label, levels, closed in shapes:
            body = {"pieces": pieces(template, levels, closed)}
            text = expand(body)
            if feature == "ads":
                out.append({"name": f"nesting-{name}-{label}", "feature": "ads", "command": "parse", "request": c,
                            "body": body, "expected": bridge(AD_BRIDGE, {"op": "parse", "body": text})})
            else:
                out.append({"name": f"nesting-{name}-{label}", "feature": "chapters", "command": "validate",
                            "request": small, "reply": {"body": body}, "model": CHAPTERS_MODEL,
                            "expected": bridge(CHAPTERS_BRIDGE, {"op": "validate", "request": small, "body": text})})
    # Whole runs: an ignored member nested to the boundary changes nothing.
    for depth in (128, 129):
        nest = "[" * (depth - 1) + "]" * (depth - 1)
        body = gemini_body(ad_answer)[:-1] + ', "nested": ' + nest + "}"
        out.append({"name": f"nesting-ads-run-body-ignored-member-depth-{depth}", "feature": "ads", "command": "run",
                    "request": c, "replies": {"window-0": {"body": body}}, "model": AD_MODEL, "thinking": "medium",
                    "expected": bridge(AD_BRIDGE, {"op": "replay", "request": c, "thinking": "medium", "model": AD_MODEL,
                                                   "policy_revision": POLICY_REVISION, "replies": {"window-0": body}})})
        body = gemini_body(text=json.dumps(chapters_answer)[:-1] + ', "nested": ' + nest + "}")
        out.append({"name": f"nesting-chapters-run-answer-ignored-member-depth-{depth}", "feature": "chapters",
                    "command": "run", "request": small, "replies": {"attempt-0": {"body": body}},
                    "model": CHAPTERS_MODEL,
                    "expected": bridge(CHAPTERS_BRIDGE, {"op": "run", "request": small, "model": CHAPTERS_MODEL,
                                                         "replies": [body]})})
    return out


DIGESTED_KEYS = ("payload", "model_request")


def canonical_text(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def payload_digest(value):
    text = canonical_text(value).encode()
    return {"bytes": len(text), "sha256": __import__("hashlib").sha256(text).hexdigest()}


def digest_payloads(value):
    """Payloads and prepared requests are compared by the digest of their
    canonical text, which keeps the goldens small."""
    if isinstance(value, list):
        return [digest_payloads(v) for v in value]
    if not isinstance(value, dict):
        return value
    result = {}
    for key, item in value.items():
        if key in DIGESTED_KEYS and isinstance(item, dict):
            result[key] = payload_digest(item)
        elif key == "payloads" and isinstance(item, dict):
            result[key] = {k: payload_digest(v) for k, v in item.items()}
        else:
            result[key] = digest_payloads(item)
    return result


def flat_lines(values, per_line=12):
    lines = []
    for start in range(0, len(values), per_line):
        lines.append("        " + ", ".join(f"0x{v:X}" for v in values[start:start + per_line]) + ",")
    return "\n".join(lines)


def write_character_tables():
    """The receipt tokenizer's and `str::trim`'s view of every scalar, from
    the ad bridge (the services' own functions), as a test fixture and as
    the compiled-in tables the Swift pipeline reads, so the device never
    depends on the OS's Unicode tables."""
    classes = bridge(AD_BRIDGE, {"op": "char_classes"})
    CHAR_CLASSES.write_text(json.dumps(classes, separators=(",", ":")) + "\n")
    alphanumeric = [v for pair in classes["alphanumeric"] for v in pair]
    whitespace = [v for pair in classes["whitespace"] for v in pair]
    lowercase = []
    for scalar, mapped in classes["lowercase"]:
        lowercase += [scalar, len(mapped), *mapped]
    CHAR_TABLES.write_text(f"""// Generated by Packages/OpenCastAnalysis/scripts/generate-parity-goldens.py
// from the ad-analysis eval bridge's `char_classes` op: what the services'
// receipt tokenizer and `str::trim` make of every Unicode scalar under the
// Rust toolchain that built them. Do not edit; regenerate.

enum RustCharacterTables {{
    /// Alphanumeric scalars, as inclusive `first, last` pairs in order.
    static let alphanumeric: [UInt32] = [
{flat_lines(alphanumeric)}
    ]

    /// White_Space scalars, as inclusive `first, last` pairs in order.
    static let whitespace: [UInt32] = [
{flat_lines(whitespace)}
    ]

    /// Scalars whose lowercase form differs, as `scalar, count, mapped...`.
    static let lowercase: [UInt32] = [
{flat_lines(lowercase)}
    ]
}}
""")
    return classes


def main():
    write_character_tables()
    cases = ad_cases() + chapters_cases() + nesting_cases()
    fixtures = {}
    for case in cases:
        request = case.pop("request")
        name = request["request_id"] + ("-declared" if "declared_duration" in request["transcript"] else "")
        fixtures[name] = request
        case["fixture"] = name
        case["expected"] = digest_payloads(case["expected"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"generator": "Packages/OpenCastAnalysis/scripts/generate-parity-goldens.py",
                               "policy_revision": POLICY_REVISION, "fixtures": fixtures, "cases": cases},
                              ensure_ascii=False, separators=(",", ":")) + "\n")
    print(json.dumps({"cases": len(cases), "fixtures": len(fixtures), "bytes": OUT.stat().st_size}))


if __name__ == "__main__":
    main()
