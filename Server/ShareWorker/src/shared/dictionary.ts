// Preset deflate dictionary for share token version "1", shared with the app's
// OpenCastCore/EpisodeShareDictionary.swift. zlib favours the END of the
// dictionary, so the most common tokens go last. Changing this is a
// wire-format change: add a new version character and keep decoding "1".
// Both test suites pin the SHA-256 of its UTF-8 bytes.
export const DICTIONARY_V1 = [
  "claritaspod.com/measure/", "arttrk.com/p/", "pfx.vpixl.com/", "mgln.ai/e/", "pdst.fm/e/", "chrt.fm/track/",
  "dts.podtrac.com/redirect.mp3/", "www.podtrac.com/pts/redirect.mp3/", "verifi.podscribe.com/rss/p/",
  "prfx.byspotify.com/e/", "op3.dev/e/", "pdcn.co/e/", "chtbl.com/track/", "podtrac.com/pts/redirect.mp3/",
  "traffic.megaphone.fm/", "stitcher.simplecastaudio.com/", "media.transistor.fm/", "www.buzzsprout.com/",
  "rss.art19.com/episodes/", "content.production.cdn.art19.com/", "anchor.fm/s/", "play.podtrac.com/",
  "traffic.libsyn.com/secure/", "audio.simplecast.com/", "cdn.simplecast.com/", "media.blubrry.com/",
  "feeds.simplecast.com/", "feeds.megaphone.fm/", "feeds.buzzsprout.com/", "feeds.transistor.fm/", "feeds.libsyn.com/",
  "image.simplecastcdn.com/images/", "megaphone.imgix.net/podcasts/", "d3t3ozftmdmh3i.cloudfront.net/",
  "images.squarespace-cdn.com/content/", "storage.googleapis.com/", "cloudfront.net/", "s3.amazonaws.com/",
  "?updated=", "?aid=rss_feed", "&aid=rss_feed", "/podcast.rss", "/feed.xml", "/rss", "/podcast/",
  "3000x3000", "1400x1400", "_3000x3000", ".jpeg", ".png", ".jpg", ".m4a", ".mp3",
  "Episode ", "Ep. ", " | ", " – ", " — ", " with ", " The ", "The ",
  "-", "_", "/", "https://",
].join("");

export const DICTIONARY_V1_BYTES = new TextEncoder().encode(DICTIONARY_V1);
export const DICTIONARY_V1_SHA256 = "2d2ad4210b59d48d9d491a0319caa92685a7e50b380601f543d52d1d79951fc9";
