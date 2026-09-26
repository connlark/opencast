import { warnEvent } from "./log";
import type { MailSummary, Signals } from "./parse";

export const JEV_MODEL = "typesafe/jev";
export const CLASSIFY_TIMEOUT_MS = 15_000;
export const DEFAULT_JUNK_THRESHOLD = 0.7;

export const CATEGORIES = ["support", "feedback", "outreach", "automated", "marketing", "spam"] as const;
export type Category = (typeof CATEGORIES)[number];
export type Label = Category | "unclassified";

// The criteria are the whole prompt. They were tuned against the synthetic
// cases in eval/ and read as definitions, not instructions.
export const CRITERIA: Record<Category, string> = {
  support:
    "A person asking for help with the app: a bug, crash, sync, playback, download, account, purchase, or subscription problem",
  feedback: "A person sharing feedback, praise, a suggestion, or a feature request about the app",
  outreach:
    "A person writing individually and specifically about this app: press, a podcast listing, a partnership, or a collaboration",
  automated:
    "Machine-generated service mail: app store or platform notices, receipts, bounces, auto-replies, verification codes",
  marketing:
    "Newsletters, promotions, or templated cold pitches selling SEO, app marketing, growth, reviews, installs, or development services",
  spam: "Scams, phishing, credential or payment lures, malware, or unintelligible junk",
};

// Categories that never earn a push: the operator reads them in the inbox.
export const QUIET_CATEGORIES: readonly Category[] = ["outreach", "marketing", "spam"];
const QUIET: ReadonlySet<Label> = new Set<Label>(QUIET_CATEGORIES);

export type Decision = "notify" | "quiet";
export type PushLevel = "active" | "passive";
export type FallbackReason = "oversized" | "parse_failed" | "timeout" | "balance" | "malformed" | "error";

export interface Verdict {
  label: Label;
  decision: Decision;
  level: PushLevel | null;
  junkP: number | null;
  confidence: number | null;
  source: "jev" | "fallback";
  reason: FallbackReason | null;
  model: string | null;
  probabilities: Record<Category, number> | null;
}

export interface JevInput {
  state: Record<string, unknown>;
  questions: Record<string, unknown>;
}

export function jevInput(mail: MailSummary, inboxContext: string): JevInput {
  const from = mail.fromName ? `${mail.fromName} <${mail.fromAddress}>` : mail.fromAddress;
  return {
    state: {
      inbox: inboxContext,
      from,
      reply_to: mail.replyTo || null,
      subject: mail.subject,
      body: mail.body,
      signals: mail.signals,
    },
    questions: {
      category: {
        type: "choice",
        instructions: `What kind of message arrived at ${inboxContext}?`,
        criteria: CRITERIA,
      },
    },
  };
}

export function junkThreshold(value: string | undefined): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 && parsed <= 1 ? parsed : DEFAULT_JUNK_THRESHOLD;
}

export class MalformedAnswer extends Error {
  constructor(detail: string) {
    super(`malformed Jev answer: ${detail}`);
    this.name = "MalformedAnswer";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function probability(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1 ? value : null;
}

// The binding returns `{model, answers, usage}`; the REST API wraps the same
// object in `result`. Anything else is malformed.
export function readAnswer(response: unknown): { probabilities: Record<Category, number>; confidence: number | null; model: string | null } {
  let body = response;
  if (isRecord(body) && !("answers" in body) && isRecord(body.result)) body = body.result;
  if (!isRecord(body) || !isRecord(body.answers)) throw new MalformedAnswer("no answers");
  const answer = body.answers.category;
  if (!isRecord(answer) || !isRecord(answer.probabilities)) throw new MalformedAnswer("no category probabilities");
  const raw = answer.probabilities;
  const probabilities = {} as Record<Category, number>;
  for (const category of CATEGORIES) {
    const p = raw[category] === undefined ? 0 : probability(raw[category]);
    if (p === null) throw new MalformedAnswer(`bad probability for ${category}`);
    probabilities[category] = p;
  }
  const total = CATEGORIES.reduce((sum, c) => sum + probabilities[c], 0);
  if (total < 0.5 || total > 1.5) throw new MalformedAnswer("probabilities do not sum to one");
  return {
    probabilities,
    confidence: probability(answer.confidence),
    model: typeof body.model === "string" ? body.model : null,
  };
}

// Junk mass (the quiet categories together) decides quiet vs notify; the
// argmax only names the message. A message labeled with a quiet category whose
// junk mass falls under the threshold still pushes, passively.
export function decide(
  probabilities: Record<Category, number>,
  threshold: number,
): Pick<Verdict, "label" | "decision" | "level" | "junkP"> {
  const junkP = QUIET_CATEGORIES.reduce((sum, c) => sum + probabilities[c], 0);
  let label: Category = CATEGORIES[0];
  for (const category of CATEGORIES) {
    if (probabilities[category] > probabilities[label]) label = category;
  }
  if (junkP >= threshold) return { label, decision: "quiet", level: null, junkP };
  const level: PushLevel = label === "automated" || QUIET.has(label) ? "passive" : "active";
  return { label, decision: "notify", level, junkP };
}

// Used whenever Jev cannot answer. Bulk mail stays quiet and machine mail stays
// passive, but everything else pushes: an outage or an empty balance must never
// silence a real message.
export function fallbackVerdict(signals: Signals, reason: FallbackReason): Verdict {
  const base = { junkP: null, confidence: null, source: "fallback" as const, reason, model: null, probabilities: null };
  if (signals.list_unsubscribe || signals.precedence === "bulk" || signals.precedence === "list") {
    return { ...base, label: "marketing", decision: "quiet", level: null };
  }
  const autoSubmitted = signals.auto_submitted !== null && signals.auto_submitted !== "no";
  if (autoSubmitted || signals.empty_return_path) {
    return { ...base, label: "automated", decision: "notify", level: "passive" };
  }
  return { ...base, label: "unclassified", decision: "notify", level: "active" };
}

export function failureReason(error: unknown): FallbackReason {
  if (error instanceof MalformedAnswer) return "malformed";
  const name = error instanceof Error ? error.name : "";
  if (name === "AbortError" || name === "TimeoutError") return "timeout";
  const message = error instanceof Error ? error.message : String(error);
  if (/\b2021\b|insufficient balance/i.test(message)) return "balance";
  return "error";
}

export interface ClassifyOptions {
  // Empty only under local `wrangler dev`, whose login token cannot reach AI
  // Gateway; every deployed lane routes through its gateway.
  gatewayId: string;
  inboxContext: string;
  threshold: number;
  timeoutMs?: number;
}

type AiRun = (model: string, inputs: JevInput, options: AiOptions) => Promise<unknown>;

export async function classify(ai: Pick<Ai, "run">, mail: MailSummary, options: ClassifyOptions): Promise<Verdict> {
  try {
    const run = ai.run.bind(ai) as unknown as AiRun;
    const response = await run(JEV_MODEL, jevInput(mail, options.inboxContext), {
      ...(options.gatewayId ? { gateway: { id: options.gatewayId, collectLog: false } } : {}),
      signal: AbortSignal.timeout(options.timeoutMs ?? CLASSIFY_TIMEOUT_MS),
    });
    const { probabilities, confidence, model } = readAnswer(response);
    return {
      ...decide(probabilities, options.threshold),
      confidence,
      source: "jev",
      reason: null,
      model,
      probabilities,
    };
  } catch (error) {
    const reason = failureReason(error);
    // Error text from the binding names the failure, never the message.
    const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    warnEvent("mail_classify_failed", { reason, error: detail.slice(0, 300) });
    return fallbackVerdict(mail.signals, reason);
  }
}
