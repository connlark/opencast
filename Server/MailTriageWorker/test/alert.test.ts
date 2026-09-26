import { afterEach, describe, expect, it, vi } from "vitest";
import { alertDraft, alertTarget, idempotencyKey, sendAlert } from "../src/alert";
import { fallbackVerdict, decide, type Verdict } from "../src/classify";
import { parseMail, type MailSummary } from "../src/parse";
import { SUPPORT_P, fixture, wellFormed } from "./helpers";

const target = { url: "https://alerts.example.com/v1/notifications", credential: "cred", recipient: "rcpt" };

function verdict(): Verdict {
  return { ...decide(SUPPORT_P, 0.7), confidence: 0.9, source: "jev", reason: null, model: "jev-1.13.0", probabilities: SUPPORT_P };
}

function respond(status: number, body: unknown) {
  return vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));
}

afterEach(() => vi.restoreAllMocks());

describe("alertTarget", () => {
  it("needs all three secrets", () => {
    expect(alertTarget({ ALERT_WEBHOOK_URL: target.url, ALERT_CREDENTIAL: "c" })).toBeNull();
    expect(alertTarget({ ALERT_WEBHOOK_URL: target.url, ALERT_CREDENTIAL: "c", ALERT_RECIPIENT: "r" })).toEqual({ url: target.url, credential: "c", recipient: "r" });
  });

  it("refuses a non-HTTPS webhook", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(alertTarget({ ALERT_WEBHOOK_URL: "http://alerts.example.com/x", ALERT_CREDENTIAL: "c", ALERT_RECIPIENT: "r" })).toBeNull();
    expect(warn.mock.calls[0]?.[0]).toContain("webhook_url_not_https");
  });
});

describe("alertDraft", () => {
  it("is exactly the 14-key schema-1 draft", async () => {
    const mail = await parseMail(fixture("support.eml"));
    const draft = alertDraft(verdict(), mail, "support@example.org");
    expect(Object.keys(draft).sort()).toEqual([
      "badge", "body", "category_id", "collapse_id", "custom_data", "expiration", "interruption_level",
      "priority", "relevance_score", "schema_version", "sound", "subtitle", "thread_id", "title",
    ]);
    expect(draft).toMatchObject({
      schema_version: 1,
      title: "Jamie Rivera",
      subtitle: "Support · support@",
      sound: "default",
      badge: null,
      interruption_level: "active",
      relevance_score: null,
      category_id: null,
      thread_id: "mail-triage",
      collapse_id: null,
      expiration: "one_day",
      priority: "immediate",
      custom_data: {},
    });
    expect(draft.body.startsWith("Downloads stuck at 0%\nHi, Since updating yesterday")).toBe(true);
  });

  it("stays well under the webhook's payload limit for a huge body", async () => {
    const mail: MailSummary = {
      ...(await parseMail(fixture("support.eml"))),
      fromName: "N".repeat(500),
      subject: "S".repeat(2_000),
      body: "é📓 ".repeat(3_500),
    };
    const draft = alertDraft(verdict(), mail, "support@example.org");
    const payload = JSON.stringify({ recipient: target.recipient, draft });
    expect(new TextEncoder().encode(payload).length).toBeLessThanOrEqual(3_072);
    expect(wellFormed(draft.body)).toBe(true);
    expect(wellFormed(draft.title)).toBe(true);
  });

  it("labels a fallback verdict and uses the address when there is no display name", async () => {
    const mail = { ...(await parseMail(fixture("support.eml"))), fromName: "", subject: "" };
    const draft = alertDraft(fallbackVerdict(mail.signals, "balance"), mail, "help@example.org");
    expect(draft).toMatchObject({ title: "jamie@example.com", subtitle: "Unclassified · help@" });
    expect(draft.body.startsWith("(no subject)\n")).toBe(true);
  });
});

describe("idempotencyKey", () => {
  it("is stable per Message-ID and matches the webhook's key alphabet", async () => {
    const mail = await parseMail(fixture("support.eml"));
    const key = await idempotencyKey(mail);
    expect(key).toMatch(/^[A-Za-z0-9.:_-]{16,128}$/);
    expect(key).toMatch(/^mail-[0-9a-f]{48}$/);
    expect(await idempotencyKey({ ...mail, body: "different" })).toBe(key);
    expect(await idempotencyKey({ ...mail, messageId: "<other@example.com>" })).not.toBe(key);
  });

  it("falls back to sender, date and subject", async () => {
    const mail = { ...(await parseMail(fixture("support.eml"))), messageId: "" };
    expect(await idempotencyKey(mail)).not.toBe(await idempotencyKey({ ...mail, subject: "other" }));
  });
});

describe("sendAlert", () => {
  const draft = async () => alertDraft(verdict(), await parseMail(fixture("support.eml")), "support@example.org");

  it("posts the envelope with bearer auth and the idempotency key", async () => {
    const fetcher = respond(200, { aggregate_status: "accepted" });
    const result = await sendAlert(target, await draft(), "mail-abc", fetcher as unknown as typeof fetch);
    expect(result).toEqual({ delivered: true, status: 200, code: "accepted" });
    const [url, init] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(target.url);
    expect(init.headers).toEqual({ authorization: "Bearer cred", "content-type": "application/json", "idempotency-key": "mail-abc" });
    expect(init.signal).toBeInstanceOf(AbortSignal);
    const body = JSON.parse(init.body as string);
    expect(Object.keys(body)).toEqual(["recipient", "draft"]);
    expect(body.recipient).toBe("rcpt");
  });

  it.each(["partially_accepted", "recipient_muted", "recipient_revoked", "no_active_target"])("counts %s as delivered", async (status) => {
    const result = await sendAlert(target, await draft(), "k", respond(200, { aggregate_status: status }) as unknown as typeof fetch);
    expect(result.delivered).toBe(true);
  });

  it("treats an idempotency conflict as already delivered", async () => {
    const fetcher = respond(409, { error: { code: "idempotency_conflict" } });
    expect(await sendAlert(target, await draft(), "k", fetcher as unknown as typeof fetch)).toMatchObject({ delivered: true, status: 409 });
  });

  it.each([
    [429, { error: { code: "rate_limited" } }],
    [500, { error: { code: "internal" } }],
    [409, { error: { code: "send_in_progress" } }],
    [200, { aggregate_status: "rejected" }],
  ])("reports %s without throwing", async (status, body) => {
    const result = await sendAlert(target, await draft(), "k", respond(status, body) as unknown as typeof fetch);
    expect(result).toMatchObject({ delivered: false, status });
  });

  it("reports a network failure without throwing", async () => {
    const fetcher = vi.fn(async () => { throw new TypeError("network"); });
    expect(await sendAlert(target, await draft(), "k", fetcher as unknown as typeof fetch)).toEqual({ delivered: false, status: 0, code: "fetch_failed" });
  });
});
