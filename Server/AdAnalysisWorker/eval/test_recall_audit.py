import json
import unittest
from recall_audit import audit_input, validate_anchors


class RecallAuditTests(unittest.TestCase):
    def setUp(self):
        self.request = {"podcast_title": "Synthetic show", "ground_truth": "must not leak",
                        "segments": [{"id": 3, "start": 4, "end": 8, "text": "Join our paid feed today."},
                                     {"id": 30, "start": 40, "end": 48, "text": "Join our paid feed today."}]}
        self.cue = {"segment_id": 3, "quote": "Join our paid feed", "label": "Paid feed"}

    def test_input_whitelists_source_and_keeps_repeated_occurrences(self):
        source = audit_input(self.request)
        self.assertNotIn("must not leak", json.dumps(source))
        self.assertNotIn("start", source["segments"][0])
        self.assertEqual([s["id"] for s in source["segments"]], [3, 30])
        self.assertEqual(len(validate_anchors(self.request, {
            "spans": [self.cue, dict(self.cue, segment_id=30)]})), 2)

    def test_cue_requires_its_own_source_receipt(self):
        for change in ({"segment_id": 4}, {"segment_id": True}, {"quote": "Buy a boat"},
                       {"quote": "Join"}, {"extra": "bad"}):
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    validate_anchors(self.request, {"spans": [dict(self.cue, **change)]})


if __name__ == "__main__":
    unittest.main()
