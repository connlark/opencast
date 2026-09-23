// The token is the URL, so nothing here may carry a path, query, header, or
// payload field: event names, statuses, and the upstream hostname only.
// Observability is off (Workers Logs would attach the request URL to every
// event), so these lines appear only in a live `wrangler tail`.
type LogField = string | number | boolean;

export function logEvent(event: string, fields: Record<string, LogField> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}
