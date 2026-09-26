import { alertDraft, alertTarget, idempotencyKey, sendAlert, type AlertSecrets } from "./alert";
import { classify, fallbackVerdict, junkThreshold, type Verdict } from "./classify";
import { errorEvent, logEvent } from "./log";
import { MAX_PARSE_BYTES, parseMail, summarizeHeaders, type MailSummary } from "./parse";

export interface Env extends AlertSecrets {
  AI: Ai;
  LANE: string;
  AI_GATEWAY_ID: string;
  INBOX_CONTEXT: string;
  JUNK_THRESHOLD: string;
  FORWARD_TO?: string;
}

export interface Deps {
  fetcher?: typeof fetch;
  now?: () => number;
}

function classifyOptions(env: Env) {
  return {
    gatewayId: env.AI_GATEWAY_ID,
    inboxContext: env.INBOX_CONTEXT,
    threshold: junkThreshold(env.JUNK_THRESHOLD),
  };
}

// Parsing and classification can fail in any way without costing the forward:
// every failure becomes a header-only fallback verdict.
async function triage(message: ForwardableEmailMessage, env: Env): Promise<{ mail: MailSummary; verdict: Verdict }> {
  if (message.rawSize > MAX_PARSE_BYTES) {
    const mail = summarizeHeaders(message.headers, message.from);
    return { mail, verdict: fallbackVerdict(mail.signals, "oversized") };
  }
  let mail: MailSummary;
  try {
    mail = await parseMail(await new Response(message.raw).arrayBuffer(), message.from);
  } catch {
    mail = summarizeHeaders(message.headers, message.from);
    return { mail, verdict: fallbackVerdict(mail.signals, "parse_failed") };
  }
  return { mail, verdict: await classify(env.AI, mail, classifyOptions(env)) };
}

export function triageHeaders(verdict: Verdict): Headers {
  const headers = new Headers();
  headers.set("X-Mail-Triage", verdict.label);
  headers.set("X-Mail-Triage-Decision", verdict.decision);
  headers.set("X-Mail-Triage-Junk", verdict.junkP === null ? "n/a" : verdict.junkP.toFixed(3));
  headers.set("X-Mail-Triage-Source", verdict.reason ? `${verdict.source}; ${verdict.reason}` : verdict.source);
  return headers;
}

export async function handleEmail(message: ForwardableEmailMessage, env: Env, deps: Deps = {}): Promise<void> {
  const now = deps.now ?? Date.now;
  const started = now();
  const forwardTo = env.FORWARD_TO?.trim();
  if (!forwardTo) {
    // Throwing (rather than dropping) lets Email Routing report the failure
    // to the sending server instead of accepting mail that goes nowhere.
    errorEvent("mail_forward_failed", { lane: env.LANE, reason: "forward_to_missing" });
    throw new Error("FORWARD_TO is not configured");
  }

  let triaged: { mail: MailSummary; verdict: Verdict };
  try {
    triaged = await triage(message, env);
  } catch {
    const mail = summarizeHeaders(message.headers, message.from);
    triaged = { mail, verdict: fallbackVerdict(mail.signals, "error") };
  }
  const { mail, verdict } = triaged;

  try {
    await message.forward(forwardTo, triageHeaders(verdict));
  } catch (error) {
    errorEvent("mail_forward_failed", {
      lane: env.LANE,
      reason: error instanceof Error ? error.name : "unknown",
      label: verdict.label,
    });
    throw error;
  }

  let alert = "quiet";
  let alertStatus: number | null = null;
  if (verdict.decision === "notify") {
    const target = alertTarget(env);
    if (!target) {
      alert = "disabled";
    } else {
      const result = await sendAlert(
        target,
        alertDraft(verdict, mail, message.to),
        await idempotencyKey(mail),
        deps.fetcher,
      );
      alert = result.delivered ? "sent" : `failed:${result.code || "unknown"}`;
      alertStatus = result.status;
    }
  }

  logEvent("mail_triaged", {
    lane: env.LANE,
    label: verdict.label,
    decision: verdict.decision,
    level: verdict.level,
    source: verdict.source,
    reason: verdict.reason,
    junk_p: verdict.junkP === null ? null : Number(verdict.junkP.toFixed(4)),
    confidence: verdict.confidence,
    model: verdict.model,
    raw_size: message.rawSize,
    body_chars: mail.body.length,
    attachments: mail.signals.attachment_count,
    alert,
    alert_status: alertStatus,
    duration_ms: now() - started,
  });
}

// Development only: POST a raw .eml and get the verdict back. The eval harness
// drives this through `wrangler dev`; every other lane has no HTTP surface.
async function triageRoute(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (env.LANE !== "development" || url.pathname !== "/__triage") return new Response("Not found", { status: 404 });
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_PARSE_BYTES) return Response.json({ error: "too_large" }, { status: 413 });
  const mail = await parseMail(raw);
  const verdict = await classify(env.AI, mail, classifyOptions(env));
  return Response.json({ ...verdict, signals: mail.signals });
}

export default {
  async email(message, env) {
    await handleEmail(message, env);
  },
  async fetch(request, env) {
    return triageRoute(request, env);
  },
} satisfies ExportedHandler<Env>;
