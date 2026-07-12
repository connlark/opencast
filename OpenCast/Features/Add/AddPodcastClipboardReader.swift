import UIKit

enum AddPodcastClipboardReader {
    static func feedURLStringFromClipboard() -> String? {
        #if DEBUG
        if let testClipboardString {
            return feedURLString(from: testClipboardString)
        }
        #endif

        return feedURLString(from: UIPasteboard.general.string)
    }

    nonisolated static func feedURLString(from rawValue: String?) -> String? {
        PodcastFeedURLDetector.feedURLString(from: rawValue)
    }

    #if DEBUG
    private static var testClipboardString: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCAST_UI_TESTING"] == "1" else {
            return nil
        }

        return environment["OPENCAST_TEST_CLIPBOARD_STRING"]
    }
    #endif
}
