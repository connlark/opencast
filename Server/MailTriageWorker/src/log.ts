// One JSON object per line, so Workers Logs indexes every field. Callers pass
// only categorical values and counts: never a subject, body or address.
export type LogFields = Record<string, string | number | boolean | null | undefined>;

export function logEvent(event: string, fields: LogFields = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function warnEvent(event: string, fields: LogFields = {}): void {
  console.warn(JSON.stringify({ event, ...fields }));
}

export function errorEvent(event: string, fields: LogFields = {}): void {
  console.error(JSON.stringify({ event, ...fields }));
}
