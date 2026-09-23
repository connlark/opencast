import Foundation

enum OpenCastConstants {
    static let thisAmericanLifeFeedURL = "https://www.thisamericanlife.org/podcast/rss.xml"
    static let restIsScienceFeedURL = "https://feeds.megaphone.fm/GLT6907573392"

    static var addPodcastInitialFeedURL: String {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENCAST_UI_TESTING"] == "1",
           let override = environment["OPENCAST_DEFAULT_FEED_URL"] {
            return override
        }

        return ""
    }

    static let supportURL = URL(string: "https://support.opencast.mobile/support")!
    static let privacyPolicyURL = URL(string: "https://support.opencast.mobile/privacy")!
    static let sourceCodeURL = URL(string: "https://github.com/connlark/opencast")!
    /// Share links always use the production origin; the token works on any
    /// ShareWorker host, so a link can be replayed against a staging lane.
    static let episodeShareBaseURL = URL(string: "https://opencast.mobile/e/")!
    static let applePodcastsOPMLShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/f1cc341b82494ad09166fd9133d16cf3"
    )!
}
