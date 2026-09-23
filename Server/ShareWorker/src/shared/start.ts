// `?t=` stays outside the token so people can edit it like a YouTube link.
// Seconds are canonical; 1h2m3s is accepted.
const SECONDS = /^\d{1,6}$/;
const CLOCK = /^(?:(\d{1,3})h)?(?:(\d{1,3})m)?(?:(\d{1,3})s)?$/;
export const MAX_START_WITHOUT_DURATION = 86_400;

/** Start in whole seconds; 0 when absent, malformed, or outside [0, duration − 2] (or a day without a duration). */
export function parseStart(value: string | null, durationSeconds: number): number {
  if (!value) {
    return 0;
  }
  let seconds: number;
  if (SECONDS.test(value)) {
    seconds = Number(value);
  } else {
    const clock = CLOCK.exec(value);
    if (!clock || (clock[1] === undefined && clock[2] === undefined && clock[3] === undefined)) {
      return 0;
    }
    seconds = Number(clock[1] ?? 0) * 3600 + Number(clock[2] ?? 0) * 60 + Number(clock[3] ?? 0);
  }
  const limit = durationSeconds > 0 ? durationSeconds - 2 : MAX_START_WITHOUT_DURATION;
  return seconds <= limit ? seconds : 0;
}

/** 12:34 or 1:02:34, flooring like the app's playback clock. */
export function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}
