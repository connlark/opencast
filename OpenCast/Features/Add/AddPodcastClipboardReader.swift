import UIKit

enum AddPodcastClipboardReader {
    /// Non-prompting probe: pattern detection never triggers the
    /// paste-permission alert or marks the pasteboard as read.
    static func clipboardProbablyHasWebURL() async -> Bool {
        let patterns = try? await UIPasteboard.general.detectedPatterns(
            for: [\UIPasteboard.DetectedValues.probableWebURL]
        )
        return patterns?.contains(\UIPasteboard.DetectedValues.probableWebURL) == true
    }
}
