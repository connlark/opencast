#!/usr/bin/env python3
"""Generate or replay large RSS fixtures without putting them in app resources.

generate --output /private/tmp/opencast-feed-max.xml
serve --fixture herd=/private/tmp/opencast-feed-research-herd.xml

Replay query options: gzip=1, chunked=1, chunk=7, delay=0.01,
truncate=12345, status=503, redirect=1. Only explicitly named files are served.
"""

import argparse
import hashlib
import json
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
from urllib.parse import parse_qs, urlsplit
import zlib


def generate(path, size, count):
    prefix = b'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>OpenCast Complete Catalog Stress</title>'
    suffix = b"</channel></rss>"

    def item(index, padding=0):
        text = ("Complete searchable show notes with every historical detail. " * ((padding // 60) + 2))[:padding]
        return (f"<item><guid>stress-{index:06d}</guid><title>Historical episode {index:06d}</title>"
                f"<pubDate>Sat, 05 Sep 2026 12:00:00 +0000</pubDate>"
                f'<enclosure url="https://example.com/audio/{index:06d}.mp3" type="audio/mpeg"/>'
                f"<description><![CDATA[{text}]]></description></item>").encode()

    remaining = size - len(prefix) - len(suffix) - sum(len(item(i)) for i in range(count))
    if remaining < 0:
        raise ValueError("Requested size is too small for the item count")
    per_item, extra = divmod(remaining, count)
    digest = hashlib.sha256()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        def write(data):
            output.write(data)
            digest.update(data)
        write(prefix)
        for index in range(count):
            write(item(index, per_item + (index < extra)))
        write(suffix)
    assert path.stat().st_size == size
    manifest = {"generator_version": 1, "decoded_bytes": size, "raw_items": count,
                "sha256": digest.hexdigest(), "first_guid": "stress-000000",
                "last_guid": f"stress-{count - 1:06d}"}
    path.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest))


def serve(fixtures, bind, port):
    hashes = {}
    for name, path in fixtures.items():
        with path.open("rb") as source:
            hashes[name] = hashlib.file_digest(source, "sha256").hexdigest()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            parsed = urlsplit(self.path)
            name = parsed.path.removeprefix("/").removesuffix(".xml")
            path = fixtures.get(name)
            if path is None:
                self.send_error(404)
                return
            query = parse_qs(parsed.query)

            def value(key, default):
                return query.get(key, [default])[0]

            if value("redirect", "0") == "1":
                self.send_response(302)
                self.send_header("Location", f"/{name}.xml")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            etag = '"' + hashes[name] + '"'
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
                return
            compressed = value("gzip", "0") == "1"
            chunked = compressed or value("chunked", "0") == "1"
            chunk = max(1, min(65536, int(value("chunk", "65536"))))
            delay = max(0, min(30, float(value("delay", "0"))))
            limit = max(0, int(value("truncate", str(path.stat().st_size))))
            self.send_response(int(value("status", "200")))
            self.send_header("Content-Type", "application/rss+xml")
            self.send_header("ETag", etag)
            if compressed:
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Transfer-Encoding" if chunked else "Content-Length",
                             "chunked" if chunked else str(path.stat().st_size))
            self.end_headers()
            compressor = zlib.compressobj(wbits=31) if compressed else None

            def write(data):
                if not data:
                    return
                if chunked:
                    self.wfile.write(f"{len(data):X}\r\n".encode())
                self.wfile.write(data)
                if chunked:
                    self.wfile.write(b"\r\n")
                self.wfile.flush()

            try:
                with path.open("rb") as source:
                    remaining = limit
                    while remaining:
                        data = source.read(min(chunk, remaining))
                        if not data:
                            break
                        remaining -= len(data)
                        write(compressor.compress(data) if compressor else data)
                        if delay:
                            time.sleep(delay)
                if limit < path.stat().st_size:
                    self.close_connection = True
                    return
                if compressor:
                    write(compressor.flush())
                if chunked:
                    self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

    print(json.dumps({"bind": bind, "port": port, "fixtures": list(fixtures)}), flush=True)
    ThreadingHTTPServer((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generator = commands.add_parser("generate")
    generator.add_argument("--output", type=Path, required=True)
    generator.add_argument("--bytes", type=int, default=128 * 1024 * 1024)
    generator.add_argument("--items", type=int, default=100_000)
    server = commands.add_parser("serve")
    server.add_argument("--fixture", action="append", required=True)
    server.add_argument("--bind", default="127.0.0.1")
    server.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    if args.command == "generate":
        if args.items < 1 or args.bytes < 1:
            parser.error("Size and item count must be positive")
        generate(args.output, args.bytes, args.items)
    else:
        serve({name: Path(path).resolve(strict=True) for name, path in
               (entry.split("=", 1) for entry in args.fixture)}, args.bind, args.port)
