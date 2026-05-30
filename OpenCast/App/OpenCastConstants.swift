import Foundation

enum OpenCastConstants {
    static let debuggerAlmanacFeedURL = "https://debuggersalmanac.mindovermatterismagic.com/feed.xml"
    static let seedFeedURL = "https://seed.mindovermatterismagic.com/feed.xml"

    static var defaultFeedURL: String {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENCAST_UI_TESTING"] == "1",
           let override = environment["OPENCAST_DEFAULT_FEED_URL"] {
            return override
        }
        return debuggerAlmanacFeedURL
    }

    static var addPodcastInitialFeedURL: String {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENCAST_UI_TESTING"] == "1",
           let override = environment["OPENCAST_DEFAULT_FEED_URL"] {
            return override
        }

        return ""
    }

    static let supportURL = URL(string: "https://opencast-support.music.workers.dev/support")!
    static let privacyPolicyURL = URL(string: "https://opencast-support.music.workers.dev/privacy")!
    static let sourceCodeURL = URL(string: "https://github.com/connlark/opencast")!
    static let applePodcastsOPMLShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/1099c673de9d4b4ea34928882e7c2f4e"
    )!
}
