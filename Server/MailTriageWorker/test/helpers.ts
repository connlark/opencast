/// <reference types="vite/client" />

const FIXTURES = import.meta.glob<string>("./fixtures/*.eml", { query: "?raw", import: "default", eager: true });

export function fixture(name: string): string {
  const raw = FIXTURES[`./fixtures/${name}`];
  if (raw === undefined) throw new Error(`missing fixture ${name}`);
  return raw;
}

// True when the string holds no lone surrogate, i.e. no split code point.
export function wellFormed(text: string): boolean {
  return !/\p{Cs}/u.test(text);
}

export function jevResponse(probabilities: Record<string, number>, model = "jev-1.13.0") {
  const choice = Object.entries(probabilities).sort((a, b) => b[1] - a[1])[0]?.[0];
  return {
    model,
    answers: { category: { type: "choice", choice, probabilities, confidence: 0.9 } },
    usage: { input_tokens: 300, output_tokens: 30 },
  };
}

export const SUPPORT_P = { support: 0.9, feedback: 0.05, outreach: 0.02, automated: 0.01, marketing: 0.01, spam: 0.01 };
export const MARKETING_P = { support: 0.01, feedback: 0.01, outreach: 0.08, automated: 0.02, marketing: 0.85, spam: 0.03 };
