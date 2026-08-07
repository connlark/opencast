// TranscriptionMediaWorker: private controller for the pinned ffmpeg
// Container. The container has no internet; its only egress is the
// `r2.internal` outbound handler below, scoped to the job scratch prefixes
// of the private transcription bucket. Contract (mirrored by the Rust
// gateway's media.rs): POST /probe and POST /chunk with JSON bodies.
import { Container, ContainerProxy, getContainer } from "@cloudflare/containers";

import { isKeyAllowed, jobBindingError, SHIM_DEADLINE_MS } from "./keys";

// Required by the outbound-handler machinery: the runtime instantiates this
// proxy from the worker entrypoint to route container egress through
// outboundByHost.
export { ContainerProxy };

interface Env {
  MEDIA_CONTAINER: DurableObjectNamespace<TranscriptionMediaContainer>;
  TRANSCRIPTION_AUDIO: R2Bucket;
}

export class TranscriptionMediaContainer extends Container<Env> {
  defaultPort = 8080;
  // Billing is provisioned-GiB × running-seconds, and the idle tail after a
  // job burst was the dominant cost of this whole surface (a 43 s job paid
  // 600 s of tail). The long tail existed to amortize the 574 MB image's
  // cold start; the 55 MB ffmpeg-9 image plus the /wake ping (which overlaps
  // starts with gateway staging) makes cold starts cheap, and probe/chunk
  // already retry through them.
  sleepAfter = "90s";
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
    let key: string;
    try {
      key = decodeURIComponent(new URL(request.url).pathname.slice(1));
    } catch {
      // A malformed percent-escape must fail closed as a forbidden key, not
      // throw a URIError out of the handler (which surfaces as a 5xx/network
      // error instead of the intended 403). Phase 10 TMW-6.
      return Response.json({ error: "forbidden_key" }, { status: 403 });
    }
    if (!isKeyAllowed(request.method, key)) {
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
    const deadlineMs = SHIM_DEADLINE_MS[url.pathname];
    if (deadlineMs === undefined) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }

    // Bind the request's object keys to the job_id in its body before the
    // container (one shared instance) can be steered at another job's audio
    // (Phase 10 TMW-3). The container itself ignores job_id, so this is the
    // only place the binding is enforced. Wake carries no body/keys.
    let forwardBody: string | null = null;
    if (url.pathname === "/probe" || url.pathname === "/chunk") {
      const raw = await request.text();
      let payload: unknown;
      try {
        payload = JSON.parse(raw);
      } catch {
        return Response.json({ error: "invalid_json" }, { status: 400 });
      }
      const bindingError = jobBindingError(url.pathname, payload);
      if (bindingError !== null) {
        return Response.json({ error: bindingError }, { status: 403 });
      }
      forwardBody = raw;
    }

    // One small pinned instance; media work is sequential in pass 0. The
    // instance name tracks the image tag so an image rollout always gets a
    // fresh container instead of waiting out a sleepy old instance.
    let response: Response;
    try {
      response = await getContainer(env.MEDIA_CONTAINER, "media-pass0-10").fetch(
        new Request(url.toString(), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: forwardBody,
          signal: AbortSignal.timeout(deadlineMs),
        }),
      );
    } catch (error) {
      // workerd may surface the aborted stub fetch as a plain Error rather
      // than a DOMException, so key on the name, not the type (TMW-8).
      const name = (error as { name?: string } | null)?.name;
      if (name === "TimeoutError" || name === "AbortError") {
        console.error(`container ${url.pathname} exceeded shim deadline ${deadlineMs}ms`);
        return Response.json({ error: "media_shim_timeout" }, { status: 504 });
      }
      throw error;
    }
    if (response.status >= 500) {
      const body = await response.clone().text();
      console.error(`container ${url.pathname} -> ${response.status}: ${body.slice(0, 300)}`);
    }
    return response;
  },
};
