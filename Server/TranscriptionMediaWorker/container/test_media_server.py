import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import media_server
from media_server import (
    MediaError,
    NORMALIZED_PROFILE,
    STREAM_COPY_PROFILE,
    download_source,
    extract_bounded_chunk,
    extract_chunk,
    ffprobe,
    normalize_chunk,
    upload,
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


class _EndlessResponse:
    """Fake urlopen response: never exhausts, so only a deadline stops it."""

    status = 200
    headers: dict = {}

    def read(self, _size: int) -> bytes:
        return b"x" * 1024

    def __enter__(self) -> "_EndlessResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None


class _FixedResponse:
    """Fake urlopen response yielding exactly `body`, advertising
    `content_length` (which may over-state the body to simulate truncation)."""

    status = 200

    def __init__(self, body: bytes, content_length: int | None):
        self._body = body
        self._offset = 0
        self.headers = (
            {} if content_length is None else {"content-length": str(content_length)}
        )

    def read(self, size: int) -> bytes:
        block = self._body[self._offset : self._offset + size]
        self._offset += len(block)
        return block

    def __enter__(self) -> "_FixedResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None


class DownloadIntegrityTests(unittest.TestCase):
    def _download(self, body: bytes, content_length: int | None):
        with tempfile.TemporaryDirectory() as raw_directory:
            destination = Path(raw_directory) / "source"
            with mock.patch.object(
                media_server.urllib.request,
                "urlopen",
                lambda *a, **k: _FixedResponse(body, content_length),
            ):
                return download_source("raw/job-x/source", destination)

    def test_short_read_against_content_length_is_a_retryable_truncation(self) -> None:
        # The body is shorter than the advertised size: a clean premature EOF
        # must not be accepted as the object's true (short) identity (TMW-1).
        with self.assertRaises(MediaError) as raised:
            self._download(b"partial-bytes", content_length=1_000_000)
        self.assertEqual(raised.exception.status, 502)
        self.assertEqual(raised.exception.code, "source_truncated")

    def test_full_body_matching_content_length_succeeds(self) -> None:
        body = b"complete-object-bytes"
        sha256, total = self._download(body, content_length=len(body))
        self.assertEqual(total, len(body))
        self.assertEqual(sha256, hashlib.sha256(body).hexdigest())

    def test_missing_content_length_header_still_succeeds(self) -> None:
        body = b"length-unknown"
        _, total = self._download(body, content_length=None)
        self.assertEqual(total, len(body))


class FfmpegHardeningTests(unittest.TestCase):
    def test_all_subprocess_calls_pin_the_file_protocol_whitelist(self) -> None:
        # Untrusted media is probed/copied by ffprobe/ffmpeg; every invocation
        # must restrict the protocol surface to local files (TMW-4a).
        cases = [
            (ffprobe, (Path("in"),)),
            (extract_chunk, (Path("in"), Path("out"), 0.0, 4.0)),
            (normalize_chunk, (Path("in"), Path("out"), 0.0, 4.0)),
        ]
        for function, args in cases:
            with self.subTest(function=function.__name__):
                captured: dict = {}

                def record(cmd, **_kwargs):
                    captured["cmd"] = cmd
                    raise subprocess.TimeoutExpired(cmd, 0)

                with mock.patch.object(media_server.subprocess, "run", record):
                    with self.assertRaises(MediaError):
                        function(*args)
                cmd = captured["cmd"]
                self.assertIn("-protocol_whitelist", cmd)
                self.assertEqual(cmd[cmd.index("-protocol_whitelist") + 1], "file")


class TimeoutBudgetTests(unittest.TestCase):
    """Every external op carries a budget and expiry maps to a clean
    MediaError — a wedged socket or subprocess can never hang the container.
    """

    def test_subprocess_timeouts_map_to_clean_media_errors(self) -> None:
        cases = [
            (ffprobe, media_server.FFPROBE_TIMEOUT_SECONDS, "probe_timeout", (Path("in"),)),
            (
                extract_chunk,
                media_server.FFMPEG_TIMEOUT_SECONDS,
                "chunk_extraction_timeout",
                (Path("in"), Path("out"), 0.0, 4.0),
            ),
            (
                normalize_chunk,
                media_server.FFMPEG_TIMEOUT_SECONDS,
                "chunk_normalization_timeout",
                (Path("in"), Path("out"), 0.0, 4.0),
            ),
        ]
        for function, budget, code, args in cases:
            with self.subTest(code=code):
                captured: dict = {}

                def expired(cmd, **kwargs):
                    captured.update(kwargs)
                    raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout", 0))

                with mock.patch.object(media_server.subprocess, "run", expired):
                    with self.assertRaises(MediaError) as raised:
                        function(*args)
                self.assertEqual(raised.exception.status, 504)
                self.assertEqual(raised.exception.code, code)
                # The budget actually reaches subprocess.run — a regression
                # that drops the kwarg would hang forever again.
                self.assertEqual(captured.get("timeout"), budget)

    def test_download_wall_clock_deadline_fires_mid_stream(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            destination = Path(raw_directory) / "source"
            with mock.patch.object(media_server, "DOWNLOAD_DEADLINE_SECONDS", 0.0), \
                    mock.patch.object(
                        media_server.urllib.request, "urlopen",
                        lambda *a, **k: _EndlessResponse(),
                    ):
                with self.assertRaises(MediaError) as raised:
                    download_source("raw/job-x/source", destination)
            self.assertEqual(raised.exception.status, 504)
            self.assertEqual(raised.exception.code, "source_download_timeout")

    def test_download_socket_inactivity_maps_to_download_timeout(self) -> None:
        captured: dict = {}

        def timed_out(url, **kwargs):
            captured.update(kwargs)
            raise TimeoutError("read timed out")

        with tempfile.TemporaryDirectory() as raw_directory:
            destination = Path(raw_directory) / "source"
            with mock.patch.object(media_server.urllib.request, "urlopen", timed_out):
                with self.assertRaises(MediaError) as raised:
                    download_source("raw/job-x/source", destination)
        self.assertEqual(raised.exception.status, 504)
        self.assertEqual(raised.exception.code, "source_download_timeout")
        self.assertEqual(captured.get("timeout"), media_server.URLOPEN_TIMEOUT_SECONDS)

    def test_upload_timeout_maps_to_upload_timeout(self) -> None:
        captured: dict = {}

        def timed_out(request, **kwargs):
            captured.update(kwargs)
            raise media_server.urllib.error.URLError(TimeoutError("timed out"))

        with tempfile.TemporaryDirectory() as raw_directory:
            chunk_path = Path(raw_directory) / "chunk.mp3"
            chunk_path.write_bytes(b"mp3-bytes")
            with mock.patch.object(media_server.urllib.request, "urlopen", timed_out):
                with self.assertRaises(MediaError) as raised:
                    upload("chunks/job-x/0.mp3", chunk_path)
        self.assertEqual(raised.exception.status, 504)
        self.assertEqual(raised.exception.code, "chunk_upload_timeout")
        self.assertEqual(captured.get("timeout"), media_server.URLOPEN_TIMEOUT_SECONDS)

    def test_non_timeout_url_errors_keep_their_existing_shape(self) -> None:
        def refused(url, **kwargs):
            raise media_server.urllib.error.URLError(ConnectionRefusedError())

        with tempfile.TemporaryDirectory() as raw_directory:
            destination = Path(raw_directory) / "source"
            with mock.patch.object(media_server.urllib.request, "urlopen", refused):
                with self.assertRaises(media_server.urllib.error.URLError):
                    download_source("raw/job-x/source", destination)


if __name__ == "__main__":
    unittest.main()
