// TranscriptionMediaWorker: private controller for the pinned ffmpeg
// Container. The container has no internet; its only egress is the
// `r2.internal` outbound handler below, scoped to the job scratch prefixes
// of the private transcription bucket. Contract (mirrored by the Rust
// gateway's media.rs): POST /probe and POST /chunk with JSON bodies.
import { Container, ContainerProxy, getContainer } from "@cloudflare/containers";

// Required by the outbound-handler machinery: the runtime instantiates this
// proxy from the worker entrypoint to route container egress through
// outboundByHost.
export { ContainerProxy };

interface Env {
  MEDIA_CONTAINER: DurableObjectNamespace<TranscriptionMediaContainer>;
  TRANSCRIPTION_AUDIO: R2Bucket;
}

const ALLOWED_KEY_PATTERN = /^(raw|chunks)\/job-[A-Za-z0-9_-]+\//;
// Exact-device uploads (pass 2) are probe/chunk inputs, never container
// outputs: readable, not writable.
const READ_ONLY_KEY_PATTERN = /^uploads\/job-[A-Za-z0-9_-]+\//;

export class TranscriptionMediaContainer extends Container<Env> {
  defaultPort = 8080;
  sleepAfter = "10m";
  enableInternet = false;

  override async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === "/wake") {
      // Create-time wake (pass 0.5 A3): issue the container start command
      // without waiting for port readiness, so a cold start overlaps the
      // gateway's staging and hash-match wait. The ping must return
      // immediately and its failure must change nothing — probe/chunk
      // already retry through cold starts.
      try {
        await this.start();
      } catch (error) {
        console.warn(`wake start failed (ignored): ${String(error).slice(0, 200)}`);
      }
      return Response.json({ message: "waking" });
    }
    return super.fetch(request);
  }
}

// Assigned as an expression, NOT a `static` class field: static fields are
// defined with define semantics, which shadow the Container base class's
// static `outboundByHost` accessor — the ContainerProxy's handler registry
// stays empty and every container egress gets 520 "Origin is disallowed".
// The assignment goes through the inherited setter, which both registers the
// dispatch handlers and keeps host discovery working.
TranscriptionMediaContainer.outboundByHost = {
  "r2.internal": async (request: Request, env: Env): Promise<Response> => {
    const key = decodeURIComponent(new URL(request.url).pathname.slice(1));
    const readable = ALLOWED_KEY_PATTERN.test(key) || READ_ONLY_KEY_PATTERN.test(key);
    if (!readable || (request.method !== "GET" && !ALLOWED_KEY_PATTERN.test(key))) {
      return Response.json({ error: "forbidden_key" }, { status: 403 });
    }
    if (request.method === "GET") {
      const object = await env.TRANSCRIPTION_AUDIO.get(key);
      if (!object) {
        return Response.json({ error: "not_found" }, { status: 404 });
      }
      // Streamed: the pass-2 source cap (512 MiB) exceeds Worker memory, so
      // buffering OOMs the isolate on long episodes. R2 bodies are
      // length-aware, so exact content-length framing still reaches the
      // container egress tunnel.
      return new Response(object.body, {
        headers: { "content-length": String(object.size) },
      });
    }
    if (request.method === "PUT") {
      const body = await request.arrayBuffer();
      await env.TRANSCRIPTION_AUDIO.put(key, body);
      return Response.json({ message: "stored" });
    }
    return Response.json({ error: "method_not_allowed" }, { status: 405 });
  },
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }
    if (url.pathname !== "/probe" && url.pathname !== "/chunk" && url.pathname !== "/wake") {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    // One small pinned instance; media work is sequential in pass 0. The
    // instance name tracks the image tag so an image rollout always gets a
    // fresh container instead of waiting out a sleepy old instance.
    const response = await getContainer(env.MEDIA_CONTAINER, "media-pass0-6").fetch(request);
    if (response.status >= 500) {
      const body = await response.clone().text();
      console.error(`container ${url.pathname} -> ${response.status}: ${body.slice(0, 300)}`);
    }
    return response;
  },
};
