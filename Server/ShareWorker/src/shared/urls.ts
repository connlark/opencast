export const SITE_ORIGIN = "https://opencast.mobile";
// Absolute, so the workers.dev lanes render the same icons as the zone route.
export const BRAND_ICON_LIGHT = `${SITE_ORIGIN}/brand/icon-light-192.png`;
export const BRAND_ICON_DARK = `${SITE_ORIGIN}/brand/icon-dark-192.png`;
export const APPLE_TOUCH_ICON = `${SITE_ORIGIN}/brand/apple-touch-icon-180.png`;
export const FALLBACK_OG_IMAGE = `${SITE_ORIGIN}/opengraph-image.jpg`;

export const MAX_URL_LENGTH = 2048;

/** An absolute http(s) URL with a host, at most 2048 UTF-16 units, no controls or edge whitespace. */
export function isWebURL(value: string): boolean {
  if (value.length === 0 || value.length > MAX_URL_LENGTH || value !== value.trim() || /\p{Cc}/u.test(value)) {
    return false;
  }
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname !== "";
  } catch {
    return false;
  }
}

export function sharePath(token: string): string {
  return `/e/${token}`;
}

export function downloadPath(token: string): string {
  return `/e/${token}/download`;
}

export function canonicalURL(origin: string, token: string, start: number): string {
  return `${origin}${sharePath(token)}${start > 0 ? `?t=${start}` : ""}`;
}

/** The page is served over https, so an http enclosure is requested as https (the CSP upgrades it anyway). */
export function playableAudioURL(audioURL: string): string {
  const url = new URL(audioURL);
  if (url.protocol === "http:") {
    url.protocol = "https:";
  }
  return url.href;
}

/**
 * A CSS `url()` the source URL cannot break out of: the URL parser
 * percent-encodes quotes and drops newlines, the quotes contain parentheses,
 * and a backslash (legal in a query) is escaped so it cannot eat the closing quote.
 */
export function cssURL(value: string): string {
  return `url("${new URL(value).href.replace(/\\/g, "\\\\")}")`;
}

export function audioMimeType(audioURL: string): "audio/mp4" | "audio/mpeg" {
  return /\.(m4a|m4b|mp4)$/i.test(new URL(audioURL).pathname) ? "audio/mp4" : "audio/mpeg";
}
