import { WorkerEntrypoint } from 'cloudflare:workers';
import RustWorker from '../build/index.js';

function invoke(ctx, env, request) {
  return new RustWorker(ctx, { ...env, POLLING_CAPABILITY: 'private' }).fetch(request);
}
// Only private service bindings expose operator inspection/repair. Public HTTP
// never receives this capability, even with forged headers or matching paths.
export class PollingControl extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, request); }
}
export default class extends WorkerEntrypoint {
  fetch() { return new Response('not_found', { status: 404 }); }
  async scheduled() {
    const response = await invoke(this.ctx, this.env, new Request('https://polling.invalid/dispatch', { method: 'POST' }));
    if (!response.ok) throw new Error('poll_dispatch_failed');
    await response.text();
  }
  async queue(batch) {
    if (batch.queue.endsWith('-dlq')) {
      console.warn(JSON.stringify({ event: 'poll_dead_letters', count: batch.messages.length }));
      // The feed row is the recovery source, even after queue retention ends:
      // back the feed off and settle its generation, then drop the message.
      for (const message of batch.messages) {
        const response = await invoke(this.ctx, this.env, new Request('https://polling.invalid/dead-letter', {
          method: 'POST', body: JSON.stringify(message.body),
        }));
        await response.text();
        if (response.ok || response.status === 400) message.ack();
        else message.retry({ delaySeconds: 60 });
      }
      return;
    }
    // The message is the poll-attempt lease. Acknowledge only after the fenced
    // feed/checkpoint and event commit; any failure or crash redelivers it.
    for (const message of batch.messages) {
      const response = await invoke(this.ctx, this.env, new Request('https://polling.invalid/consume', {
        method: 'POST', body: JSON.stringify(message.body), headers: { 'x-poll-attempts': String(message.attempts ?? 1) },
      }));
      await response.text();
      if (response.ok || response.status === 400) message.ack();
      else message.retry({ delaySeconds: 60 });
    }
  }
}
