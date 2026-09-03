import UIKit

enum AddPodcastClipboardReader {
    /// Prefill for the UI-testing seam only. Production must never read the
    /// pasteboard without a user gesture — the system paste-permission alert
    /// would fire on sheet open.
    static func seededTestFeedURLString() -> String? {
        #if DEBUG
        if let testClipboardString {
            return feedURLString(from: testClipboardString)
        }
        #endif

        return nil
    }

    /// Non-prompting probe: pattern detection never triggers the
    /// paste-permission alert or marks the pasteboard as read.
    static func clipboardProbablyHasWebURL() async -> Bool {
        #if DEBUG
        if testClipboardString != nil {
            return true
        }
        #endif

        let patterns = try? await UIPasteboard.general.detectedPatterns(
            for: [\UIPasteboard.DetectedValues.probableWebURL]
        )
        return patterns?.contains(\UIPasteboard.DetectedValues.probableWebURL) == true
    }

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
