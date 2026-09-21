// Capability adapter only. Validation, authorization, D1 and delivery policy
// live in Rust. Request headers/URLs can never set this invocation capability.
import { WorkerEntrypoint } from 'cloudflare:workers';
import RustWorker from '../build/index.js';

function invoke(ctx, env, capability, request) {
  return new RustWorker(ctx, { ...env, NOTIFICATION_CAPABILITY: capability }).fetch(request);
}
export class FeedEvents extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, 'feed_polling', request); }
}
export class AdAnalysisEvents extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, 'ad_analysis', request); }
}
export class RemoteTranscriptionEvents extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, 'remote_transcription', request); }
}
export default class extends WorkerEntrypoint {
  fetch(request) { return invoke(this.ctx, this.env, '', request); }
  scheduled(event) { return new RustWorker(this.ctx, this.env).scheduled(event); }
  async queue(batch) {
    for (const message of batch.messages) {
      const request = new Request('https://notification.invalid/queue', {
        method: 'POST', body: JSON.stringify({ queue: batch.queue, message: message.body }),
      });
      const response = await invoke(this.ctx, this.env, 'queue', request);
      if (response.ok || response.status === 400) message.ack();
      else message.retry({ delaySeconds: 60 });
    }
  }
}

// The observation producer receives storage, release brakes and its narrow
// FeedEvents binding. It has no APNs credentials or public ingress authority.
export class FeedObservations extends WorkerEntrypoint {
  fetch(request) {
    const { APP_ATTEST_DB, FEED_SNAPSHOTS, NOTIFICATION_ENVIRONMENT,
      NOTIFICATION_FEED_OBSERVATION, NOTIFICATION_CLEANUP, NOTIFICATION_EVENTS } = this.env;
    return invoke(this.ctx, { APP_ATTEST_DB, FEED_SNAPSHOTS,
      NOTIFICATION_ENVIRONMENT, NOTIFICATION_FEED_OBSERVATION, NOTIFICATION_CLEANUP, NOTIFICATION_EVENTS }, 'feed_observations', request);
  }
}

// Private current-engine operations. Public requests cannot select this authority.
export class FeedControl extends WorkerEntrypoint {
  fetch(request) {
    const { APP_ATTEST_DB, EPISODE_DELIVERY_QUEUE, NOTIFICATION_ENVIRONMENT } = this.env;
    return invoke(this.ctx, { APP_ATTEST_DB, EPISODE_DELIVERY_QUEUE,
      NOTIFICATION_ENVIRONMENT }, 'feed_control', request);
  }
}
