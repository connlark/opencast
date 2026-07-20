import type { Env } from './types';

const PUSHOVER_URL = 'https://api.pushover.net/1/messages.json';

/**
 * Shared content-free operations alert path. Callers construct messages from
 * counts and opaque job IDs only; secrets and response bodies are never logged.
 */
export async function sendPushoverAlert(
  env: Env,
  title: string,
  message: string,
): Promise<void> {
  if (!env.PUSHOVER_APP_TOKEN || !env.PUSHOVER_USER_KEY) {
    throw new Error('pushover secrets are not configured');
  }
  const body = new URLSearchParams({
    token: env.PUSHOVER_APP_TOKEN,
    user: env.PUSHOVER_USER_KEY,
    title,
    message,
  });
  const response = await fetch(PUSHOVER_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!response.ok) {
    throw new Error(`pushover returned HTTP ${response.status}`);
  }
}

export function notificationEnvironmentMismatchMessage(): string {
  return 'notification_environment_mismatch=1';
}
