// Temporary remote RSS fixture only: no storage, secrets, APNs, or cron.
const encode = text => new TextEncoder().encode(text);
const item = index => `<item><guid>fixture-${index}</guid><title>Fixture ${index}</title><pubDate>Sat, 05 Sep 2026 12:00:00 +0000</pubDate><enclosure url="https://example.com/${index}.mp3"/></item>`;
export default {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path.includes('fetch')) {
      await scheduler.wait(60_000);
      return new Response('<rss><channel><title>Late</title>' + item(0) + '</channel></rss>');
    }
    if (path.includes('read') || path.includes('parse')) {
      let position = 0;
      let closed = false;
      return new Response(new ReadableStream({
        async pull(controller) {
          if (position === 0) {
            position++;
            controller.enqueue(encode('<rss><channel><title>Pending</title>'));
          } else if (path.includes('parse') && position < 501) {
            await scheduler.wait(25);
            if (closed) return;
            const start = position++ * 160;
            controller.enqueue(encode(Array.from({ length: 160 }, (_, i) => item(start + i)).join('')));
          } else {
            await scheduler.wait(60_000);
            if (!closed) controller.close();
          }
        },
        cancel() {
          closed = true;
          console.log(JSON.stringify({ event: 'fixture_cancelled', phase: path, chunks: position }));
        },
      }), { headers: { 'content-type': 'application/rss+xml', etag: '"incomplete"' } });
    }
    return new Response('<rss><channel><title>Complete</title>' + item(0) + '</channel></rss>',
      { headers: { 'content-type': 'application/rss+xml', etag: '"complete"' } });
  },
};
