import { describe, expect, it } from "vitest";
import { collapseWhitespace, htmlToText, parseMail, summarizeHeaders, truncateUtf8 } from "../src/parse";
import { fixture, wellFormed } from "./helpers";

describe("parseMail", () => {
  it("reads a plain-text message with its sender, auth results and links", async () => {
    const mail = await parseMail(fixture("support.eml"), "jamie@example.com");
    expect(mail.fromName).toBe("Jamie Rivera");
    expect(mail.fromAddress).toBe("jamie@example.com");
    expect(mail.subject).toBe("Downloads stuck at 0%");
    expect(mail.messageId).toBe("<support-1@example.com>");
    expect(mail.body).toContain("sits at 0% on my");
    expect(mail.signals).toMatchObject({
      list_unsubscribe: false,
      empty_return_path: false,
      spf: "pass",
      dkim: "pass",
      dmarc: "pass",
      link_count: 1,
      attachment_count: 0,
    });
  });

  it("falls back to HTML converted to text, dropping style and script", async () => {
    const mail = await parseMail(fixture("html-only.eml"));
    expect(mail.fromName).toBe("Priya N.");
    expect(mail.body).toContain("I’ve been using the app for a month and it's great.");
    expect(mail.body).toContain("sleep timer");
    expect(mail.body).not.toMatch(/color: red|alert\(1\)|ignored|<p>/);
  });

  it("decodes quoted-printable latin-1 bodies and encoded-word headers", async () => {
    const mail = await parseMail(fixture("qp-latin1.eml"));
    expect(mail.fromName).toBe("René Müller");
    expect(mail.subject).toBe("Problème de synchronisation");
    expect(mail.body).toContain("ma bibliothèque ne se synchronise plus entre mon iPhone et mon iPad");
  });

  it("flags a bounce from its null return path and Auto-Submitted header", async () => {
    const mail = await parseMail(fixture("bounce.eml"), "");
    expect(mail.signals.empty_return_path).toBe(true);
    expect(mail.signals.auto_submitted).toBe("auto-replied");
  });

  it("reads list headers and prefers the text part of a newsletter", async () => {
    const mail = await parseMail(fixture("newsletter.eml"));
    expect(mail.signals).toMatchObject({ list_unsubscribe: true, precedence: "bulk", link_count: 3 });
    expect(mail.signals.list_id).toContain("weekly.example.com");
    expect(mail.body.startsWith("This week: ASO tricks")).toBe(true);
  });

  it("counts real attachments", async () => {
    const mail = await parseMail(fixture("attachment.eml"));
    expect(mail.signals.attachment_count).toBe(1);
    expect(mail.body).toContain("crashes when I open the Inbox");
  });

  it("caps the body handed to the classifier", async () => {
    const long = fixture("support.eml").replace("Thanks,", "x".repeat(20_000));
    expect((await parseMail(long)).body.length).toBe(6_000);
  });
});

describe("summarizeHeaders", () => {
  it("builds a body-less summary from decoded top-level headers", () => {
    const headers = new Headers({
      from: "=?iso-8859-1?q?Ren=E9?= <rene@example.com>",
      subject: `=?utf-8?b?${btoa(String.fromCharCode(...new TextEncoder().encode("Hello 📓")))}?=`,
      "message-id": "<h-1@example.com>",
      "list-unsubscribe": "<https://example.com/u>",
    });
    const mail = summarizeHeaders(headers, "bounce@example.com");
    expect(mail).toMatchObject({ fromName: "René", fromAddress: "rene@example.com", subject: "Hello 📓", body: "" });
    expect(mail.signals.list_unsubscribe).toBe(true);
  });

  it("uses the envelope sender when From is missing", () => {
    expect(summarizeHeaders(new Headers(), "x@example.com").fromAddress).toBe("x@example.com");
  });
});

describe("text helpers", () => {
  it("converts block HTML to lines and decodes entities", () => {
    expect(htmlToText("<p>a &amp; b</p><div>c&#x41;</div>")).toBe("a & b\ncA");
  });

  it("collapses whitespace", () => {
    expect(collapseWhitespace("  a\n\n b\t c ")).toBe("a b c");
  });

  it("truncates UTF-8 without splitting code points", () => {
    const text = "é".repeat(10) + "📓".repeat(10);
    for (let limit = 4; limit < 60; limit++) {
      const out = truncateUtf8(text, limit);
      expect(new TextEncoder().encode(out).length).toBeLessThanOrEqual(limit);
      expect(out).not.toContain("�");
      expect(wellFormed(out)).toBe(true);
    }
    expect(truncateUtf8("short", 100)).toBe("short");
  });
});
