// The storage-fixture build's test entry, loaded beside the build's index.js:
// /slice-e/ reaches the build's separate slice_e_fetch export; every other
// path is the build's own fixture dispatcher. A request with an
// x-test-execution header carries this entry's own AbortSignal, aborted by
// POST /__abort with that key: the invocation owner's abort, which Miniflare's
// socket disconnects do not reliably deliver.
import Fixture from './index.js';
const executions = new Map();
const pause = () => new Promise(resolve => setTimeout(resolve, 5));
export default class extends Fixture {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/__abort') {
      const execution = executions.get(await request.text());
      if (execution) execution.requested = true;
      return Response.json({ found: !!execution });
    }
    const key = request.headers.get('x-test-execution');
    let execution, watching;
    if (key) {
      const controller = new AbortController();
      execution = { requested: false, finished: false };
      executions.set(key, execution);
      request = new Request(request, { signal: controller.signal });
      // Native I/O must be cancelled in its originating request context.
      watching = (async () => {
        while (!execution.requested && !execution.finished) await pause();
        if (execution.requested) controller.abort();
      })();
    }
    try {
      return await (path.startsWith('/slice-e/') ? this.slice_e_fetch(request, this.env) : super.fetch(request));
    } finally {
      if (execution) { execution.finished = true; executions.delete(key); await watching; }
    }
  }
}
