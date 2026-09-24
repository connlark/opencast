// Stand-in podcast host for the browser tests. The page loads audio and
// artwork straight from the host named in the token, so every token the tests
// mint points here.
//
// One port speaks both HTTPS and plain HTTP (the first byte of a TLS
// connection is 0x16): the browser needs HTTPS because the page's CSP carries
// `upgrade-insecure-requests`, while workerd, which proxies Download, refuses
// the self-signed certificate and is pointed at the http:// form instead.
//
// Audio is synthesized rather than committed: a silent 32 kbps mono CBR MP3
// whose byte offset is exactly 4000 × seconds, so any length is free and a
// Range request can be answered arithmetically. WebKit's media stack requires
// Range and 206; `page.route` cannot stand in for it.
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { crc32, deflateSync } from "node:zlib";

// MPEG-1 Layer III, 32 kbps, 32 kHz, mono, no CRC, no padding: 144 bytes per
// 1152-sample frame. Zero side info and main data decode as silence.
const FRAME = Buffer.alloc(144);
FRAME.set([0xff, 0xfb, 0x18, 0xc0]);
export const AUDIO_BYTES_PER_SECOND = 4000;
const MAX_AUDIO_SECONDS = 48 * 3600;

export interface MediaRequest {
  at: number;
  method: string;
  path: string;
  range: string | null;
  referer: string | null;
  userAgent: string | null;
  status: number;
}

export interface MediaServer {
  port: number;
  httpsOrigin: string;
  httpOrigin: string;
  close(): Promise<void>;
}

export async function startMediaServer(tls: { key: string; cert: string }): Promise<MediaServer> {
  const log: MediaRequest[] = [];
  const handler = (request: http.IncomingMessage, response: http.ServerResponse) => {
    const url = new URL(request.url ?? "/", "http://media.invalid");
    response.on("finish", () => {
      if (url.pathname === "/__log") return;
      log.push({
        at: Date.now(),
        method: request.method ?? "",
        path: `${url.pathname}${url.search}`,
        range: request.headers.range ?? null,
        referer: request.headers.referer ?? null,
        userAgent: request.headers["user-agent"] ?? null,
        status: response.statusCode,
      });
    });
    route(url, request, response, log).catch((error: unknown) => {
      if (!response.headersSent) response.writeHead(500);
      response.end(String(error));
    });
  };

  const secure = https.createServer(tls, handler);
  const plain = http.createServer(handler);
  const sockets = new Set<net.Socket>();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.once("data", (first) => {
      socket.pause();
      socket.unshift(first);
      (first[0] === 0x16 ? secure : plain).emit("connection", socket);
      process.nextTick(() => socket.resume());
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as net.AddressInfo;
  return {
    port,
    httpsOrigin: `https://127.0.0.1:${port}`,
    httpOrigin: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
  };
}

async function route(url: URL, request: http.IncomingMessage, response: http.ServerResponse, log: MediaRequest[]) {
  const path = url.pathname;
  // Tests read what the host saw (Referer, Range) from here, filtered by a
  // probe query string they put in their own token's URLs.
  if (path === "/__log") {
    const probe = url.searchParams.get("probe") ?? "";
    const entries = log.filter((entry) => entry.path.includes(probe));
    response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify(entries));
    return;
  }

  // /audio/<seconds>.mp3, optionally /audio/slow/<ms>/<seconds>.mp3 (every
  // response, ranges included, waits <ms> before its headers).
  const audio = /^\/audio\/(?:slow\/(\d{1,6})\/)?(\d{1,6})\.mp3$/.exec(path);
  if (audio) {
    const delay = Number(audio[1] ?? 0);
    const seconds = Number(audio[2]);
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    if (seconds < 1 || seconds > MAX_AUDIO_SECONDS) {
      response.writeHead(404).end();
      return;
    }
    serveAudio(request, response, Math.round(seconds / 0.036) * FRAME.length);
    return;
  }
  // Wrong content type: the Download proxy only passes audio and octet-stream.
  if (path === "/audio/page.html") {
    response.writeHead(200, { "content-type": "text/html" }).end("<!doctype html><title>not audio</title>");
    return;
  }

  const art = ART[path];
  if (art) {
    response.writeHead(200, { "content-type": art.type, "content-length": art.body.length, "cache-control": "no-store" });
    response.end(request.method === "HEAD" ? undefined : art.body);
    return;
  }

  response.writeHead(404, { "content-type": "text/plain" }).end("not found\n");
}

function serveAudio(request: http.IncomingMessage, response: http.ServerResponse, size: number) {
  const headers: Record<string, string | number> = {
    "content-type": "audio/mpeg",
    "accept-ranges": "bytes",
    "cache-control": "no-store",
  };
  let start = 0;
  let end = size - 1;
  let status = 200;
  const range = request.headers.range;
  if (range !== undefined) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!match || (match[1] === "" && match[2] === "")) {
      response.writeHead(416, { "content-range": `bytes */${size}` }).end();
      return;
    }
    if (match[1] === "") {
      start = Math.max(0, size - Number(match[2]));
    } else {
      start = Number(match[1]);
      if (match[2] !== "") end = Math.min(end, Number(match[2]));
    }
    if (start >= size || start > end) {
      response.writeHead(416, { "content-range": `bytes */${size}` }).end();
      return;
    }
    status = 206;
    headers["content-range"] = `bytes ${start}-${end}/${size}`;
  }
  headers["content-length"] = end - start + 1;
  response.writeHead(status, headers);
  if (request.method === "HEAD") {
    response.end();
    return;
  }
  writeFrames(response, start, end + 1);
}

// Streams bytes [from, to) of the repeated frame, pausing for backpressure so
// a three-hour file never sits in memory.
function writeFrames(response: http.ServerResponse, from: number, to: number) {
  const CHUNK = FRAME.length * 512;
  const block = Buffer.concat(Array.from({ length: 1024 }, () => FRAME));
  let offset = from;
  const pump = () => {
    while (offset < to) {
      const length = Math.min(CHUNK, to - offset);
      const phase = offset % FRAME.length;
      const ok = response.write(block.subarray(phase, phase + length));
      offset += length;
      if (!ok) {
        response.once("drain", pump);
        return;
      }
    }
    response.end();
  };
  response.on("close", () => {
    offset = to;
  });
  pump();
}

// Solid-colour PNGs with a diagonal band, big enough that the page's own
// sizing (not the image's) decides the layout.
function png(width: number, height: number, [r, g, b]: [number, number, number]): Buffer {
  const row = 1 + width * 3;
  const raw = Buffer.alloc(row * height);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const band = Math.abs(x - y) < Math.min(width, height) / 10;
      const at = y * row + 1 + x * 3;
      raw[at] = band ? 255 - r : r;
      raw[at + 1] = band ? 255 - g : g;
      raw[at + 2] = band ? 255 - b : b;
    }
  }
  const chunk = (type: string, data: Buffer) => {
    const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    body.copy(out, 4);
    out.writeUInt32BE(crc32(body), 8 + data.length);
    return out;
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

export const TINY_PNG = png(4, 4, [120, 90, 200]);

const ART: Record<string, { type: string; body: Buffer }> = {
  "/art/square.png": { type: "image/png", body: png(600, 600, [214, 96, 64]) },
  "/art/wide.png": { type: "image/png", body: png(1600, 400, [40, 120, 200]) },
  "/art/tall.png": { type: "image/png", body: png(300, 1200, [60, 160, 90]) },
  "/art/cover.svg": {
    type: "image/svg+xml",
    body: Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#264653"/><circle cx="50" cy="50" r="30" fill="#e9c46a"/></svg>',
    ),
  },
};
