import Foundation

/// The preset DEFLATE dictionary for share token version `1`. Part of the wire
/// format: the worker's `src/shared/dictionary.ts` holds the same string, both
/// test suites pin its SHA-256, and any change is a new version character.
/// zlib favours the end of a dictionary, so the most common tokens stay last.
public enum EpisodeShareDictionary {
    public static let v1: [UInt8] = Array(v1Parts.joined().utf8)
    public static let v1SHA256 = "2d2ad4210b59d48d9d491a0319caa92685a7e50b380601f543d52d1d79951fc9"

    private static let v1Parts = [
        "claritaspod.com/measure/", "arttrk.com/p/", "pfx.vpixl.com/", "mgln.ai/e/", "pdst.fm/e/",
        "chrt.fm/track/", "dts.podtrac.com/redirect.mp3/", "www.podtrac.com/pts/redirect.mp3/",
        "verifi.podscribe.com/rss/p/", "prfx.byspotify.com/e/", "op3.dev/e/", "pdcn.co/e/", "chtbl.com/track/",
        "podtrac.com/pts/redirect.mp3/", "traffic.megaphone.fm/", "stitcher.simplecastaudio.com/",
        "media.transistor.fm/", "www.buzzsprout.com/", "rss.art19.com/episodes/",
        "content.production.cdn.art19.com/", "anchor.fm/s/", "play.podtrac.com/", "traffic.libsyn.com/secure/",
        "audio.simplecast.com/", "cdn.simplecast.com/", "media.blubrry.com/", "feeds.simplecast.com/",
        "feeds.megaphone.fm/", "feeds.buzzsprout.com/", "feeds.transistor.fm/", "feeds.libsyn.com/",
        "image.simplecastcdn.com/images/", "megaphone.imgix.net/podcasts/", "d3t3ozftmdmh3i.cloudfront.net/",
        "images.squarespace-cdn.com/content/", "storage.googleapis.com/", "cloudfront.net/",
        "s3.amazonaws.com/", "?updated=", "?aid=rss_feed", "&aid=rss_feed", "/podcast.rss", "/feed.xml", "/rss",
        "/podcast/", "3000x3000", "1400x1400", "_3000x3000", ".jpeg", ".png", ".jpg", ".m4a", ".mp3",
        "Episode ", "Ep. ", " | ", " \u{2013} ", " \u{2014} ", " with ", " The ", "The ", "-", "_", "/",
        "https://"
    ]
}
