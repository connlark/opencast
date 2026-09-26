import { describe, expect, it, vi } from "vitest";
import {
  CATEGORIES,
  JEV_MODEL,
  classify,
  decide,
  fallbackVerdict,
  junkThreshold,
  readAnswer,
  type Category,
} from "../src/classify";
import { parseMail, type Signals } from "../src/parse";
import { MARKETING_P, SUPPORT_P, fixture, jevResponse } from "./helpers";

const options = { gatewayId: "mail-triage", inboxContext: "the support inbox of an app", threshold: 0.7 };

function stubAi(result: unknown) {
  const run = vi.fn(async () => {
    if (result instanceof Error) throw result;
    return result;
  });
  return { ai: { run } as unknown as Pick<Ai, "run">, run };
}

function only(category: Category): Record<Category, number> {
  return Object.fromEntries(CATEGORIES.map((c) => [c, c === category ? 1 : 0])) as Record<Category, number>;
}

const quietSignals: Signals = {
  list_unsubscribe: false, list_id: null, precedence: null, auto_submitted: null,
  x_auto_response_suppress: null, empty_return_path: false, spf: null, dkim: null, dmarc: null,
  attachment_count: 0, link_count: 0,
};

describe("classify", () => {
  it("calls Jev through the gateway with logs off, a deadline signal and the typed question", async () => {
    const mail = await parseMail(fixture("support.eml"));
    const { ai, run } = stubAi(jevResponse(SUPPORT_P));
    const verdict = await classify(ai, mail, options);

    expect(run).toHaveBeenCalledTimes(1);
    const [model, input, opts] = run.mock.calls[0] as unknown as [string, any, AiOptions];
    expect(model).toBe(JEV_MODEL);
    expect(opts.gateway).toEqual({ id: "mail-triage", collectLog: false });
    expect(opts.signal).toBeInstanceOf(AbortSignal);
    expect(input.state).toMatchObject({
      inbox: "the support inbox of an app",
      from: "Jamie Rivera <jamie@example.com>",
      subject: "Downloads stuck at 0%",
      signals: { dmarc: "pass" },
    });
    expect(input.questions.category.type).toBe("choice");
    expect(Object.keys(input.questions.category.criteria)).toEqual([...CATEGORIES]);

    expect(verdict).toMatchObject({ label: "support", decision: "notify", level: "active", source: "jev", model: "jev-1.13.0" });
    expect(verdict.junkP).toBeCloseTo(0.04);
  });

  it("skips the gateway only when no gateway id is configured", async () => {
    const mail = await parseMail(fixture("support.eml"));
    const { ai, run } = stubAi(jevResponse(SUPPORT_P));
    await classify(ai, mail, { ...options, gatewayId: "" });
    const opts = (run.mock.calls[0] as unknown as [string, unknown, AiOptions])[2];
    expect(opts.gateway).toBeUndefined();
    expect(opts.signal).toBeInstanceOf(AbortSignal);
  });

  it("accepts the REST-shaped response wrapped in result", async () => {
    const mail = await parseMail(fixture("newsletter.eml"));
    const { ai } = stubAi({ result: jevResponse(MARKETING_P) });
    expect(await classify(ai, mail, options)).toMatchObject({ label: "marketing", decision: "quiet", level: null });
  });

  it.each([
    [new Error("AiError: 2021: Insufficient balance"), "balance"],
    [Object.assign(new Error("The operation was aborted due to timeout"), { name: "TimeoutError" }), "timeout"],
    [Object.assign(new Error("aborted"), { name: "AbortError" }), "timeout"],
    [new Error("InferenceUpstreamError"), "error"],
    [{ answers: {} }, "malformed"],
    [{ answers: { category: { probabilities: { support: 2 } } } }, "malformed"],
    [{ answers: { category: { probabilities: { support: 0.1 } } } }, "malformed"],
    ["not an object", "malformed"],
  ])("falls back on %s", async (result, reason) => {
    const mail = await parseMail(fixture("support.eml"));
    const { ai } = stubAi(result);
    expect(await classify(ai, mail, options)).toMatchObject({
      label: "unclassified", decision: "notify", level: "active", source: "fallback", reason,
    });
  });

  it("aborts a slow classifier with a real signal", async () => {
    const mail = await parseMail(fixture("support.eml"));
    const ai = {
      run: (_model: string, _input: unknown, opts: AiOptions) =>
        new Promise((_, reject) => opts.signal?.addEventListener("abort", () => reject(opts.signal?.reason))),
    } as unknown as Pick<Ai, "run">;
    expect(await classify(ai, mail, { ...options, timeoutMs: 20 })).toMatchObject({ source: "fallback", reason: "timeout" });
  });
});

describe("decide", () => {
  it.each([
    ["support", "notify", "active"],
    ["feedback", "notify", "active"],
    ["outreach", "quiet", null],
    ["automated", "notify", "passive"],
    ["marketing", "quiet", null],
    ["spam", "quiet", null],
  ] as const)("%s → %s", (category, decision, level) => {
    expect(decide(only(category), 0.7)).toMatchObject({ label: category, decision, level });
  });

  it("goes quiet exactly at the threshold and pushes passively just under it", () => {
    const at = { support: 0.3, feedback: 0, outreach: 0, automated: 0, marketing: 0.4, spam: 0.3 };
    expect(decide(at, 0.7)).toMatchObject({ decision: "quiet", label: "marketing" });
    const under = { ...at, support: 0.31, spam: 0.29 };
    expect(decide(under, 0.7)).toMatchObject({ decision: "notify", level: "passive", label: "marketing" });
  });

  it("sums junk mass across outreach, marketing and spam", () => {
    const split = { support: 0.2, feedback: 0.05, outreach: 0.05, automated: 0, marketing: 0.35, spam: 0.35 };
    expect(decide(split, 0.7).decision).toBe("quiet");
    // The first production mail: outreach-labeled, low confidence, with
    // real spam mass. It pushed under the old two-category sum.
    const pitch = { support: 0.03, feedback: 0.02, outreach: 0.42, automated: 0.06, marketing: 0.3, spam: 0.17 };
    expect(decide(pitch, 0.7)).toMatchObject({ decision: "quiet", label: "outreach" });
    const personal = { support: 0.5, feedback: 0.2, outreach: 0.25, automated: 0, marketing: 0.05, spam: 0 };
    expect(decide(personal, 0.7)).toMatchObject({ decision: "notify", label: "support", level: "active" });
  });
});

describe("readAnswer", () => {
  it("treats a category missing from the probabilities as zero", () => {
    const { probabilities } = readAnswer(jevResponse({ support: 0.6, spam: 0.4 }));
    expect(probabilities).toMatchObject({ support: 0.6, spam: 0.4, feedback: 0 });
  });
});

describe("fallbackVerdict", () => {
  it("keeps bulk mail quiet", () => {
    expect(fallbackVerdict({ ...quietSignals, list_unsubscribe: true }, "balance")).toMatchObject({ decision: "quiet", label: "marketing" });
    expect(fallbackVerdict({ ...quietSignals, precedence: "list" }, "timeout")).toMatchObject({ decision: "quiet" });
  });

  it("pushes machine mail passively", () => {
    expect(fallbackVerdict({ ...quietSignals, auto_submitted: "auto-replied" }, "error")).toMatchObject({ label: "automated", level: "passive" });
    expect(fallbackVerdict({ ...quietSignals, empty_return_path: true }, "error")).toMatchObject({ label: "automated", level: "passive" });
    expect(fallbackVerdict({ ...quietSignals, auto_submitted: "no" }, "error")).toMatchObject({ label: "unclassified" });
  });

  it("pushes everything else as unclassified", () => {
    expect(fallbackVerdict(quietSignals, "oversized")).toMatchObject({ label: "unclassified", decision: "notify", level: "active", reason: "oversized" });
  });
});

describe("junkThreshold", () => {
  it.each([["0.8", 0.8], ["1", 1], ["", 0.7], ["0", 0.7], ["abc", 0.7], [undefined, 0.7], ["1.5", 0.7]])("%s → %s", (input, expected) => {
    expect(junkThreshold(input)).toBe(expected);
  });
});
