# Corpus provenance

Real publisher output, kept byte for byte as it was served: no trimming, no reformatting, no entity fixes.

- `feeds/<slug>.xml` holds whole podcast feeds as served; `chapters/<slug>.json` holds `podcast:chapters`
  documents those feeds declare.
- Every file has exactly one row below. A file without a row does not belong here.
- Public feeds only, and the documents they declare: nothing behind authentication, and no private, subscriber,
  or tokenized feed URL.
- Nothing is ever refetched in place. A newer capture of the same feed or document is a new file whose slug ends
  in its capture date (`<slug>-<yyyymmdd>`), and the older file stays while a test cites it.

## Chapters documents (`chapters/`)

The feed URL is the one the episode was found in. The document URL is exactly what the feed item declares, which
is what the app fetches. Fetched is when the document was fetched (UTC); bytes are `wc -c` of the file here.
Served as and the cache headers are what the document host returned.

| File | Feed URL | Document URL, as the feed declares it | Fetched | Bytes | Hosting platform | Served as | Cache headers | What it exercises |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `audacitytopodcast-ep452.json` | `https://feeds.podcastmirror.com/theaudacitytopodcast` | `https://storage.podchapters.com/j973bkwgxk3jpd4j3mw02g6b717p8s52/tap452/metadata.json` | 2026-11-13T03:20:10Z | 4955 | PodChapters document host, WordPress + PowerPress feed | `application/json` | no cache-control; etag `"70fe8cca7257080c170ef7a4e4d6628b"`, last-modified Wed, 21 Oct 2026 01:01:49 GMT | Version "1.2" (not three-part), a root description, millisecond-precision starts, img and url keys, and a toc:false entry that repeats an earlier listed chapter's title. |
| `buildyoursaas-ep163.json` | `https://feeds.transistor.fm/build-your-saas` | `https://share.transistor.fm/s/9c22a01c/chapters.json` | 2026-11-13T03:19:23Z | 1380 | Transistor | `application/json+chapters; charset=utf-8` | cache-control `max-age=300, public, must-revalidate`; etag `W/"da1387a7db7de890ab6d18228708457a"` | Fractional starts with endTime on every entry; the first chapter starts at 133.56 s, not 0. Pretty-printed. |
| `buzzcast-ep253.json` | `https://rss.buzzsprout.com/231452.rss` (requested as `https://feeds.buzzsprout.com/231452.rss`, which redirects there) | `https://www.buzzsprout.com/231452/20079447/chapters.json` | 2026-11-13T03:18:25Z | 991 | Buzzsprout | `application/json; charset=utf-8` | cache-control `max-age=0, private, must-revalidate`; etag `W/"54c92c0d68d9b339ab45732050d1500e"` | Version 1.1.0, startTime and title only, whole-second starts written as floats (0.0). |
| `changelog-ep689.json` | `https://changelog.com/podcast/feed` | `https://changelog.com/podcast/689/chapters` | 2026-11-13T03:18:25Z | 2340 | changelog.com (self-hosted) | `application/json; charset=utf-8` | cache-control `no-store, must-revalidate` | endTime on every entry, an unknown number key, url on sponsor entries, curly-apostrophe titles, minified. |
| `hrcoffeetime-ep188.json` | `https://feeds.captivate.fm/hr-coffee-time/` | `https://transcripts.captivate.fm/chapter-0ef84ee0-7a25-4bf1-8df4-633104edff6d.json` | 2026-11-13T03:20:10Z | 1665 | Captivate | `application/json` (the feed declares `application/json+chapters`) | no cache-control; etag `"b5b4e520e340d0ef7590758dabcfe7ca"`, last-modified Mon, 02 Nov 2026 19:12:38 GMT | endTime on every entry, integer starts, a fractional final endTime. |
| `noagenda-ep1916.json` | `https://feeds.noagendaassets.com/noagenda.xml` (requested as `http://feed.nashownotes.com/rss.xml`, which redirects there) | `https://reflex.livewire.io/chapters/podcast/856cd618-7f34-57ea-9b84-3600f1f65e7f/item/http://1916.noagendanotes.com/chapters/https://mp3s.nashownotes.com/NA-1916-Chapters.json` | 2026-11-13T03:18:26Z | 14690 | Sovereign Feeds, document served through the LiveWire reflex proxy | `application/json; charset=utf-8` | cache-control `private, no-cache`; etag `3a421eddbfe009228be07db3c98733f773e5169e` | The longest list found (61 entries over 5.8 hours): img on every entry, fractional starts, and nine toc:false boost entries with endTime, the first of which shares start 0 with the real first chapter and precedes it. |
| `podcasting20-ep277.json` | `https://feeds.podcastindex.org/pc20.xml` | `https://reflex.livewire.io/chapters/podcast/917393e3-1b1e-5cef-ace4-edaa54e1f810/item/PC20-277/chapters/https://mp3s.nashownotes.com/PC20-277-Chapters.json` | 2026-11-13T03:18:28Z | 4621 | Sovereign Feeds, document served through the LiveWire reflex proxy | `application/json; charset=utf-8` | cache-control `private, no-cache`; etag `390c76a1fefddee0ba6c9c2186777527250cc037` | Em-dash titles, url keys, one toc:false boost entry carrying endTime and img, root author, title, podcastName and fileName keys. The declared URL embeds the origin URL in its path. |
| `podcastinsider-ep484.json` | `https://feeds.blubrry.com/feeds/podcastinsider.xml` | `https://transcripts.blubrry.com/podcastinsider/chapters/1789423671.json` | 2026-11-13T03:19:23Z | 61 | Blubrry | `application/json+chapters`, from S3 | cache-control `public, no-cache`; etag `"da65a722531032bc899eb734cc875cae"`, last-modified Mon, 14 Sep 2026 22:07:52 GMT | A placeholder the feed still declares: one entry at 0 with a null title, so it decodes to no chapters. |
