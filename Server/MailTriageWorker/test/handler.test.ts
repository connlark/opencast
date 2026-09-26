import { afterEach, describe, expect, it, vi } from "vitest";
import worker, { handleEmail, type Env } from "../src/index";
import { MAX_PARSE_BYTES } from "../src/parse";
import { MARKETING_P, SUPPORT_P, fixture, jevResponse } from "./helpers";

function message(raw: string, overrides: Partial<ForwardableEmailMessage> = {}) {
  const bytes = new TextEncoder().encode(raw);
  const headerBlock = raw.split("\n\n")[0] ?? "";
  const headers = new Headers();
  for (const line of headerBlock.split("\n")) {
    const at = line.indexOf(":");
    if (at > 0) headers.append(line.slice(0, at), line.slice(at + 1).trim());
  }
  const forward = vi.fn(async (_to: string, _headers?: Headers) => ({ messageId: "<fwd@example.org>" }));
  const msg = {
    from: "sender@example.com",
    to: "support@example.org",
    headers,
    rawSize: bytes.length,
    raw: new Response(bytes).body!,
    forward,
    setReject: vi.fn(),
    reply: vi.fn(),
    ...overrides,
  } as unknown as ForwardableEmailMessage;
  return { msg, forward };
}

function env(run: (...args: unknown[]) => Promise<unknown>, extra: Partial<Env> = {}): Env {
  return {
    AI: { run } as unknown as Ai,
    LANE: "production",
    AI_GATEWAY_ID: "mail-triage",
    INBOX_CONTEXT: "the support inbox of an app",
    JUNK_THRESHOLD: "0.7",
    FORWARD_TO: "owner@example.net",
    ALERT_WEBHOOK_URL: "https://alerts.example.com/v1/notifications",
    ALERT_CREDENTIAL: "cred",
    ALERT_RECIPIENT: "rcpt",
    ...extra,
  };
}

const accepted = () => vi.fn(async () => Response.json({ aggregate_status: "accepted" }));

function logged(spy: { mock: { calls: unknown[][] } }) {
  const line = spy.mock.calls.map((c) => String(c[0])).find((l) => l.includes('"mail_triaged"'));
  return line ? JSON.parse(line) : null;
}

afterEach(() => vi.restoreAllMocks());

describe("handleEmail", () => {
  it("forwards once with only X- triage headers, then pushes real mail", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg, forward } = message(fixture("support.eml"));
    const fetcher = accepted();
    await handleEmail(msg, env(async () => jevResponse(SUPPORT_P)), { fetcher: fetcher as unknown as typeof fetch });

    expect(forward).toHaveBeenCalledTimes(1);
    const [to, headers] = forward.mock.calls[0]!;
    expect(to).toBe("owner@example.net");
    const names = [...headers!.keys()];
    expect(names.every((n) => n.startsWith("x-"))).toBe(true);
    expect(headers!.get("X-Mail-Triage")).toBe("support");
    expect(headers!.get("X-Mail-Triage-Decision")).toBe("notify");
    expect(headers!.get("X-Mail-Triage-Source")).toBe("jev");
    expect(headers!.get("X-Mail-Triage-Junk")).toBe("0.040");

    expect(fetcher).toHaveBeenCalledTimes(1);
    const entry = logged(log);
    expect(entry).toMatchObject({ event: "mail_triaged", label: "support", decision: "notify", alert: "sent", alert_status: 200, model: "jev-1.13.0" });
    const text = JSON.stringify(entry);
    expect(text).not.toMatch(/Downloads|jamie|example\.com|owner/);
  });

  it("forwards junk tagged and sends no push", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg, forward } = message(fixture("newsletter.eml"));
    const fetcher = accepted();
    await handleEmail(msg, env(async () => jevResponse(MARKETING_P)), { fetcher: fetcher as unknown as typeof fetch });
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]![1]!.get("X-Mail-Triage-Decision")).toBe("quiet");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("still forwards and pushes when the classifier throws", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg, forward } = message(fixture("support.eml"));
    const fetcher = accepted();
    await handleEmail(msg, env(async () => { throw new Error("2021: Insufficient balance"); }), { fetcher: fetcher as unknown as typeof fetch });
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]![1]!.get("X-Mail-Triage-Source")).toBe("fallback; balance");
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("still forwards when the raw stream cannot be read", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const broken = new ReadableStream({ pull(controller) { controller.error(new Error("stream reset")); } });
    const { msg, forward } = message(fixture("support.eml"), { raw: broken } as Partial<ForwardableEmailMessage>);
    const run = vi.fn();
    await handleEmail(msg, env(run), { fetcher: accepted() as unknown as typeof fetch });
    expect(run).not.toHaveBeenCalled();
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]![1]!.get("X-Mail-Triage-Source")).toBe("fallback; parse_failed");
  });

  it("skips parsing and classification for oversized mail", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg, forward } = message(fixture("newsletter.eml"), { rawSize: MAX_PARSE_BYTES + 1 } as Partial<ForwardableEmailMessage>);
    const run = vi.fn();
    const fetcher = accepted();
    await handleEmail(msg, env(run), { fetcher: fetcher as unknown as typeof fetch });
    expect(run).not.toHaveBeenCalled();
    expect(forward.mock.calls[0]![1]!.get("X-Mail-Triage-Source")).toBe("fallback; oversized");
    expect(forward.mock.calls[0]![1]!.get("X-Mail-Triage-Decision")).toBe("quiet");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("rethrows a failed forward and sends no push", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { msg, forward } = message(fixture("support.eml"));
    forward.mockRejectedValueOnce(new Error("destination not verified"));
    const fetcher = accepted();
    await expect(handleEmail(msg, env(async () => jevResponse(SUPPORT_P)), { fetcher: fetcher as unknown as typeof fetch })).rejects.toThrow("destination not verified");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("refuses to accept mail with no forward destination", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { msg, forward } = message(fixture("support.eml"));
    await expect(handleEmail(msg, env(vi.fn(), { FORWARD_TO: "" }))).rejects.toThrow("FORWARD_TO");
    expect(forward).not.toHaveBeenCalled();
  });

  it("never throws for a failed push", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg, forward } = message(fixture("support.eml"));
    const fetcher = vi.fn(async () => new Response("{}", { status: 500 }));
    await handleEmail(msg, env(async () => jevResponse(SUPPORT_P)), { fetcher: fetcher as unknown as typeof fetch });
    expect(forward).toHaveBeenCalledTimes(1);
    expect(logged(log)).toMatchObject({ alert: "failed:unknown", alert_status: 500 });
  });

  it("logs alerting as disabled without secrets", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const { msg } = message(fixture("support.eml"));
    await handleEmail(msg, env(async () => jevResponse(SUPPORT_P), { ALERT_CREDENTIAL: undefined }));
    expect(logged(log)).toMatchObject({ alert: "disabled" });
  });
});

describe("fetch", () => {
  const fetchWorker = (request: Request, e: Env) => worker.fetch(request as Parameters<typeof worker.fetch>[0], e);
  const post = (body: string) => new Request("http://localhost/__triage", { method: "POST", body });

  it("serves /__triage only in development", async () => {
    const run = vi.fn(async () => jevResponse(SUPPORT_P));
    const prod = await fetchWorker(post(fixture("support.eml")), env(run));
    expect(prod.status).toBe(404);
    expect(run).not.toHaveBeenCalled();

    const dev = await fetchWorker(post(fixture("support.eml")), env(run, { LANE: "development" }));
    expect(dev.status).toBe(200);
    expect(await dev.json()).toMatchObject({ label: "support", decision: "notify", source: "jev" });
  });

  it("404s any other path in development", async () => {
    const res = await fetchWorker(new Request("http://localhost/"), env(vi.fn(), { LANE: "development" }));
    expect(res.status).toBe(404);
  });
});
