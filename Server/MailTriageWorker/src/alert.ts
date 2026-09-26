import type { Label, Verdict } from "./classify";
import { warnEvent } from "./log";
import { collapseWhitespace, truncateUtf8, type MailSummary } from "./parse";

export const ALERT_TIMEOUT_MS = 10_000;
const TITLE_BYTES = 160;
const BODY_BYTES = 1_200;

// The operator alert webhook. The endpoint is deployment configuration, not
// source: alerting is on only when all three secrets are set, and a non-HTTPS
// URL is refused so the bearer credential never travels in clear.
export interface AlertTarget {
  url: string;
  credential: string;
  recipient: string;
}

export interface AlertSecrets {
  ALERT_WEBHOOK_URL?: string;
  ALERT_CREDENTIAL?: string;
  ALERT_RECIPIENT?: string;
}

export function alertTarget(env: AlertSecrets): AlertTarget | null {
  const url = env.ALERT_WEBHOOK_URL?.trim();
  const credential = env.ALERT_CREDENTIAL?.trim();
  const recipient = env.ALERT_RECIPIENT?.trim();
  if (!url || !credential || !recipient) return null;
  if (!url.startsWith("https://")) {
    warnEvent("mail_alert_misconfigured", { reason: "webhook_url_not_https" });
    return null;
  }
  return { url, credential, recipient };
}

const LABELS: Record<Label, string> = {
  support: "Support",
  feedback: "Feedback",
  outreach: "Outreach",
  automated: "Automated",
  marketing: "Marketing",
  spam: "Spam",
  unclassified: "Unclassified",
};

// Exactly the schema-1 draft the webhook requires: every field present, none
// extra (unknown fields are rejected).
export function alertDraft(verdict: Verdict, mail: MailSummary, recipientAddress: string) {
  const local = recipientAddress.split("@")[0] || recipientAddress;
  const subject = collapseWhitespace(mail.subject) || "(no subject)";
  const excerpt = collapseWhitespace(mail.body);
  const title = collapseWhitespace(mail.fromName) || mail.fromAddress || "Unknown sender";
  return {
    schema_version: 1,
    title: truncateUtf8(title, TITLE_BYTES),
    subtitle: `${LABELS[verdict.label]} · ${local}@`,
    body: truncateUtf8(excerpt ? `${subject}\n${excerpt}` : subject, BODY_BYTES),
    sound: "default",
    badge: null,
    interruption_level: verdict.level ?? "passive",
    relevance_score: null,
    category_id: null,
    thread_id: "mail-triage",
    collapse_id: null,
    expiration: "one_day",
    priority: "immediate",
    custom_data: {},
  };
}

// Stable per message, so a redelivered message replays the same key and the
// webhook's idempotency ledger drops the duplicate push.
export async function idempotencyKey(mail: MailSummary): Promise<string> {
  const identity = mail.messageId || `${mail.fromAddress}|${mail.date}|${mail.subject}`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `mail-${hex.slice(0, 48)}`;
}

export interface AlertResult {
  delivered: boolean;
  status: number;
  code: string;
}

const DELIVERED = new Set(["accepted", "partially_accepted", "recipient_muted", "recipient_revoked", "no_active_target"]);

export async function sendAlert(
  target: AlertTarget,
  draft: ReturnType<typeof alertDraft>,
  key: string,
  fetcher: typeof fetch = fetch,
): Promise<AlertResult> {
  try {
    const response = await fetcher(target.url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${target.credential}`,
        "content-type": "application/json",
        "idempotency-key": key,
      },
      body: JSON.stringify({ recipient: target.recipient, draft }),
      signal: AbortSignal.timeout(ALERT_TIMEOUT_MS),
    });
    const body: unknown = await response.json().catch(() => null);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const aggregate = typeof record.aggregate_status === "string" ? record.aggregate_status : "";
    const error = typeof record.error === "object" && record.error !== null ? (record.error as Record<string, unknown>) : {};
    const code = typeof error.code === "string" ? error.code : typeof record.code === "string" ? record.code : "";
    // A replay after an uncertain response is settled by the webhook's
    // idempotency ledger, whose conflict answer means it already has the send.
    const delivered =
      (response.status === 409 && code === "idempotency_conflict") ||
      (response.status === 200 && DELIVERED.has(aggregate));
    return { delivered, status: response.status, code: code || aggregate };
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    return { delivered: false, status: 0, code: name === "TimeoutError" || name === "AbortError" ? "timeout" : "fetch_failed" };
  }
}
