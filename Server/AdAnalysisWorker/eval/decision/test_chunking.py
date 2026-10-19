import unittest

from decision import chunking
from decision.fakes import request


class ChunkingTests(unittest.TestCase):
    def test_segments_tile_array_order_with_sparse_ids(self):
        req = request([5.0] * 23, ids=[1000 - 37 * i for i in range(23)])  # descending, sparse
        chunks = chunking.make(req["segments"], {"kind": "segments", "size": 10})
        chunking.check_tiling(chunks, 23)
        self.assertEqual([(c.first, c.last) for c in chunks], [(0, 9), (10, 19), (20, 22)])
        self.assertEqual(chunks[1].start, req["segments"][10]["start"])
        self.assertEqual(chunks[2].label, "C2")

    def test_seconds_pack_without_mixing_long_segments(self):
        req = request([160, 12, 22, 15, 30, 158, 6.8], ids=[10, 20, 30, 40, 50, 60, 120])
        chunks = chunking.make(req["segments"], {"kind": "seconds", "size": 30})
        chunking.check_tiling(chunks, 7)
        self.assertEqual([(c.first, c.last) for c in chunks], [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6)])
        whisper = request([6.4] * 20)
        packed = chunking.make(whisper["segments"], chunking.parse_spec("sec30"))
        self.assertTrue(all(c.duration <= 30 for c in packed))
        self.assertEqual(packed[0].last - packed[0].first + 1, 4)

    def test_spec_ids_and_regions(self):
        self.assertEqual(chunking.spec_id(chunking.parse_spec("seg10")), "seg10")
        self.assertEqual(chunking.spec_id(chunking.parse_spec("sec30")), "sec30")
        chunks = chunking.make(request([1.0] * 30)["segments"], {"kind": "segments", "size": 10})
        self.assertEqual(chunking.region(chunks, -1, 1), (0, 19))
        self.assertEqual(chunking.region(chunks, 1, 3), (10, 29))
        with self.assertRaises(ValueError):
            chunking.check_tiling(chunks[:2], 30)


if __name__ == "__main__":
    unittest.main()
