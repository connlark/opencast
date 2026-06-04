import Foundation

enum OpenCastConstants {
    static let thisAmericanLifeFeedURL = "https://www.thisamericanlife.org/podcast/rss.xml"
    static let libriVoxCommunityFeedURL = "https://feeds.feedburner.com/LibrivoxCommunityPodcast"

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
    static let applePodcastsOPMLShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/1099c673de9d4b4ea34928882e7c2f4e"
    )!
}
