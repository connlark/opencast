import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from media_server import (
    MediaError,
    NORMALIZED_PROFILE,
    STREAM_COPY_PROFILE,
    extract_bounded_chunk,
    ffprobe,
)


class BoundedChunkTests(unittest.TestCase):
    def make_source(self, directory: Path, bitrate: str) -> Path:
        source = directory / f"source-{bitrate}.mp3"
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4",
                "-ac", "2", "-c:a", "libmp3lame", "-b:a", bitrate, str(source),
            ],
            check=True,
        )
        return source

    def test_stream_copy_stays_byte_bounded_without_normalization(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            source = self.make_source(directory, "128k")
            output = directory / "copy.mp3"

            profile = extract_bounded_chunk(source, output, 0.0, 4.0, 100_000)

            self.assertEqual(profile, STREAM_COPY_PROFILE)
            self.assertLessEqual(output.stat().st_size, 100_000)

    def test_oversized_mp3_normalizes_to_the_proven_speech_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            source = self.make_source(directory, "320k")
            first = directory / "normalized-first.mp3"
            second = directory / "normalized-second.mp3"

            first_profile = extract_bounded_chunk(source, first, 0.0, 4.0, 100_000)
            second_profile = extract_bounded_chunk(source, second, 0.0, 4.0, 100_000)

            self.assertEqual(first_profile, NORMALIZED_PROFILE)
            self.assertEqual(second_profile, NORMALIZED_PROFILE)
            self.assertLessEqual(first.stat().st_size, 100_000)
            self.assertEqual(
                hashlib.sha256(first.read_bytes()).digest(),
                hashlib.sha256(second.read_bytes()).digest(),
            )
            audio_streams = [
                stream
                for stream in ffprobe(first).get("streams", [])
                if stream.get("codec_type") == "audio"
            ]
            self.assertEqual(len(audio_streams), 1)
            self.assertEqual(audio_streams[0].get("codec_name"), "mp3")
            self.assertEqual(audio_streams[0].get("sample_rate"), "44100")
            self.assertEqual(audio_streams[0].get("channels"), 1)

    def test_normalized_chunk_still_fails_closed_at_the_raw_byte_cap(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            source = self.make_source(directory, "320k")
            output = directory / "too-large.mp3"

            with self.assertRaises(MediaError) as raised:
                extract_bounded_chunk(source, output, 0.0, 4.0, 10_000)

            self.assertEqual(raised.exception.status, 413)
            self.assertEqual(raised.exception.code, "normalized_chunk_too_large")
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
