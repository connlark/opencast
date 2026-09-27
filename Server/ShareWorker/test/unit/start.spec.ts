import { describe, expect, it } from "vitest";
import { formatClock, parseStart } from "../../src/shared/start.ts";

describe("parseStart", () => {
  it.each([
    [null, 0],
    ["", 0],
    ["754", 754],
    ["0", 0],
    ["1h2m3s", 3723],
    ["2m", 120],
    ["45s", 45],
    ["1h", 3600],
    ["h", 0],
    ["abc", 0],
    ["-1", 0],
    ["1.5", 0],
    ["999999999", 0],
    ["1000h", 0],
  ])("%s → %i", (value, expected) => {
    expect(parseStart(value)).toBe(expected);
  });

  it("honours any start under a day, past the feed's duration included", () => {
    // Dynamic ad insertion makes the served file longer or shorter than the
    // RSS figure on every request, so the feed's duration is not a bound.
    expect(parseStart("3598")).toBe(3598);
    expect(parseStart("3599")).toBe(3599);
    expect(parseStart("4173")).toBe(4173);
    expect(parseStart("59m59s")).toBe(3599);
    expect(parseStart("86400")).toBe(86400);
    expect(parseStart("24h")).toBe(86400);
    expect(parseStart("86401")).toBe(0);
    expect(parseStart("24h1s")).toBe(0);
  });
});

describe("formatClock", () => {
  it.each([
    [0, "0:00"],
    [59.9, "0:59"],
    [754, "12:34"],
    [3600, "1:00:00"],
    [3754, "1:02:34"],
    [-5, "0:00"],
  ])("%d → %s", (seconds, text) => {
    expect(formatClock(seconds)).toBe(text);
  });
});
