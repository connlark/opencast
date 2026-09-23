import { describe, expect, it } from "vitest";
import { formatClock, parseStart } from "../../src/shared/start.ts";

describe("parseStart", () => {
  it.each([
    [null, 3600, 0],
    ["", 3600, 0],
    ["754", 3600, 754],
    ["0", 3600, 0],
    ["1h2m3s", 7200, 3723],
    ["2m", 3600, 120],
    ["45s", 3600, 45],
    ["1h", 7200, 3600],
    ["h", 3600, 0],
    ["abc", 3600, 0],
    ["-1", 3600, 0],
    ["1.5", 3600, 0],
    ["999999999", 0, 0],
    ["1000h", 0, 0],
  ])("%s with duration %i → %i", (value, duration, expected) => {
    expect(parseStart(value, duration)).toBe(expected);
  });

  it("keeps starts within the duration less two seconds", () => {
    expect(parseStart("3598", 3600)).toBe(3598);
    expect(parseStart("3599", 3600)).toBe(0);
    expect(parseStart("59m59s", 3600)).toBe(0);
  });

  it("allows up to a day when the duration is unknown", () => {
    expect(parseStart("86400", 0)).toBe(86400);
    expect(parseStart("86401", 0)).toBe(0);
    expect(parseStart("24h", 0)).toBe(86400);
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
