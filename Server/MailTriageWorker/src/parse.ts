import PostalMime, { addressParser, decodeWords, type Address, type Email } from "postal-mime";

// Messages above this size skip MIME parsing entirely. Running out of memory or
// CPU cannot be caught, and a crashed invocation must never cost the forward.
export const MAX_PARSE_BYTES = 4 * 1024 * 1024;

// Jev's input is capped well below its context window, and a triage decision
// never needs more than the opening of a message.
export const MAX_BODY_CHARS = 6_000;

export type AuthResult = string | null;

export interface Signals {
  list_unsubscribe: boolean;
  list_id: string | null;
  precedence: string | null;
  auto_submitted: string | null;
  x_auto_response_suppress: string | null;
  empty_return_path: boolean;
  spf: AuthResult;
  dkim: AuthResult;
  dmarc: AuthResult;
  attachment_count: number;
  link_count: number;
}

export interface MailSummary {
  fromName: string;
  fromAddress: string;
  replyTo: string;
  subject: string;
  body: string;
  messageId: string;
  date: string;
  signals: Signals;
}

type HeaderLookup = (name: string) => string | null;

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

// Authentication-Results carries `method=result` pairs. The receiving hop's own
// header comes first; ARC results are consulted only when it is missing.
function authResult(get: HeaderLookup, method: string): AuthResult {
  const pattern = new RegExp(`(?:^|[\\s;])${method}=([a-z]+)`, "i");
  for (const header of ["authentication-results", "arc-authentication-results"]) {
    const match = get(header)?.match(pattern);
    if (match?.[1]) return match[1].toLowerCase();
  }
  return null;
}

// `envelopeFrom` is the SMTP MAIL FROM when the caller has it; an empty one is
// a bounce (RFC 5321 null reverse-path), as is a `Return-Path: <>` header.
export function headerSignals(get: HeaderLookup, envelopeFrom?: string): Signals {
  const returnPath = get("return-path")?.trim();
  return {
    list_unsubscribe: clean(get("list-unsubscribe")) !== null,
    list_id: clean(get("list-id")),
    precedence: clean(get("precedence"))?.toLowerCase() ?? null,
    auto_submitted: clean(get("auto-submitted"))?.toLowerCase() ?? null,
    x_auto_response_suppress: clean(get("x-auto-response-suppress")),
    empty_return_path: envelopeFrom === "" || envelopeFrom === "<>" || returnPath === "<>",
    spf: authResult(get, "spf"),
    dkim: authResult(get, "dkim"),
    dmarc: authResult(get, "dmarc"),
    attachment_count: 0,
    link_count: 0,
  };
}

function mailbox(address: Address | undefined): { name: string; address: string } {
  if (!address) return { name: "", address: "" };
  if (address.address !== undefined) return { name: address.name, address: address.address };
  const first = address.group[0];
  return { name: address.name || first?.name || "", address: first?.address ?? "" };
}

function formatAddress(address: Address | undefined): string {
  const { name, address: email } = mailbox(address);
  if (name && email) return `${name} <${email}>`;
  return name || email;
}

const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  mdash: "—", ndash: "–", hellip: "…", rsquo: "’", lsquo: "‘", rdquo: "”", ldquo: "“",
};

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (whole, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return ENTITIES[name.toLowerCase()] ?? whole;
  });
}

// Good enough for classification, not rendering: block elements become line
// breaks, invisible content is dropped, everything else loses its tags.
export function htmlToText(html: string): string {
  return decodeEntities(
    html
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<(script|style|head|title)\b[\s\S]*?<\/\1\s*>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|tr|li|h[1-6]|blockquote|table)\s*>/gi, "\n")
      .replace(/<[^>]*>/g, " "),
  )
    .replace(/[ \t\f\v ]+/g, " ")
    .replace(/ *\n[\n ]*/g, "\n")
    .trim();
}

export function collapseWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

// Truncates to at most `maxBytes` of UTF-8 without splitting a code point.
export function truncateUtf8(text: string, maxBytes: number, ellipsis = "…"): string {
  const encoder = new TextEncoder();
  if (encoder.encode(text).length <= maxBytes) return text;
  const budget = maxBytes - encoder.encode(ellipsis).length;
  let used = 0;
  let out = "";
  for (const char of text) {
    const size = encoder.encode(char).length;
    if (used + size > budget) break;
    used += size;
    out += char;
  }
  return out + ellipsis;
}

function countLinks(email: Email): number {
  const hrefs = email.html?.match(/<a\b[^>]*\bhref\s*=/gi)?.length ?? 0;
  const bare = email.text?.match(/\bhttps?:\/\/\S+/gi)?.length ?? 0;
  return Math.max(hrefs, bare);
}

export function summarize(email: Email, envelopeFrom?: string): MailSummary {
  const headers = new Map<string, string>();
  for (const { key, value } of email.headers) {
    const existing = headers.get(key);
    headers.set(key, existing === undefined ? value : `${existing}, ${value}`);
  }
  const signals = headerSignals((name) => headers.get(name) ?? null, envelopeFrom);
  signals.attachment_count = email.attachments.filter((a) => a.disposition !== "inline").length;
  signals.link_count = countLinks(email);

  const text = email.text?.trim() ? email.text : htmlToText(email.html ?? "");
  const from = mailbox(email.from);
  return {
    fromName: from.name,
    fromAddress: from.address,
    replyTo: (email.replyTo ?? []).map(formatAddress).filter(Boolean).join(", "),
    subject: email.subject?.trim() ?? "",
    body: text.trim().slice(0, MAX_BODY_CHARS),
    messageId: email.messageId?.trim() ?? "",
    date: email.date?.trim() ?? "",
    signals,
  };
}

export async function parseMail(raw: ArrayBuffer | Uint8Array | string, envelopeFrom?: string): Promise<MailSummary> {
  return summarize(await PostalMime.parse(raw), envelopeFrom);
}

// The oversized and failed-parse path: everything comes from the top-level
// headers Email Routing already decoded, and there is no body.
export function summarizeHeaders(headers: Headers, envelopeFrom?: string): MailSummary {
  const get = (name: string) => headers.get(name);
  const decode = (value: string | null) => {
    if (!value) return "";
    try {
      return decodeWords(value).trim();
    } catch {
      return value.trim();
    }
  };
  let from = { name: "", address: "" };
  try {
    from = mailbox(addressParser(decode(get("from")))[0]);
  } catch {
    // An unparseable From leaves the sender blank; the push falls back to
    // the envelope sender below.
  }
  return {
    fromName: from.name,
    fromAddress: from.address || envelopeFrom || "",
    replyTo: decode(get("reply-to")),
    subject: decode(get("subject")),
    body: "",
    messageId: get("message-id")?.trim() ?? "",
    date: get("date")?.trim() ?? "",
    signals: headerSignals(get, envelopeFrom),
  };
}
