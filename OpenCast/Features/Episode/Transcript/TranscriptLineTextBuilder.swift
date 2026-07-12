import SwiftUI

/// Applies precomputed styling to a transcript line. All string searching
/// happens up front (TranscriptKaraokeLayout, TranscriptSearchIndex) so this
/// stays allocation-only on the render path.
nonisolated enum TranscriptLineTextBuilder {
    static func attributedText(
        text: String,
        spokenUpperBound: String.Index?,
        highlightRanges: [Range<String.Index>]?
    ) -> AttributedString {
        var attributed = AttributedString(text)

        if let spokenUpperBound {
            if let spokenRange = Range(text.startIndex..<spokenUpperBound, in: attributed) {
                attributed[spokenRange].foregroundColor = .primary
            }
            if let unspokenRange = Range(spokenUpperBound..<text.endIndex, in: attributed) {
                attributed[unspokenRange].foregroundColor = .primary.opacity(0.35)
            }
        }

        if let highlightRanges {
            for range in highlightRanges {
                guard let matchRange = Range(range, in: attributed) else {
                    continue
                }
                attributed[matchRange].backgroundColor = .yellow.opacity(0.4)
            }
        }

        return attributed
    }
}
