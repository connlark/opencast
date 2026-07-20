import OpenCastTranscription
import SwiftUI

struct EpisodeTranscriptLineView: View {
    let segment: OpenCastTranscriptSegment
    let isActive: Bool
    let isCurrentEpisode: Bool
    let showsTimestamp: Bool
    let adSpanLabel: String?
    let isAdSpanStart: Bool
    let searchHighlightRanges: [Range<String.Index>]?
    let karaokeSpokenUpperBound: String.Index?
    let karaokeLayout: TranscriptKaraokeLayout?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                if isAdSpanStart, let adSpanLabel {
                    Label(adSpanLabel, systemImage: "megaphone")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if showsTimestamp {
                    Text(segment.start.formattedPlaybackDuration)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                lineText
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, adSpanLabel == nil ? 0 : 11)
            .overlay(alignment: .leading) {
                if adSpanLabel != nil {
                    Capsule()
                        .fill(.orange)
                        .frame(width: 3)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(segment.text)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("Plays from this point")
    }

    @ViewBuilder
    private var lineText: some View {
        if let karaokeLayout, let karaokeSpokenUpperBound {
            Text(TranscriptLineTextBuilder.attributedText(
                text: karaokeLayout.text,
                spokenUpperBound: karaokeSpokenUpperBound,
                highlightRanges: searchHighlightRanges
            ))
        } else if let searchHighlightRanges {
            Text(TranscriptLineTextBuilder.attributedText(
                text: segment.text,
                spokenUpperBound: nil,
                highlightRanges: searchHighlightRanges
            ))
        } else {
            Text(segment.text)
        }
    }

    private var isDimmed: Bool {
        isCurrentEpisode && !isActive
    }

    private var accessibilityValueText: String {
        let timecode = segment.start.formattedPlaybackDuration
        guard let adSpanLabel else {
            return timecode
        }
        return "\(timecode), Sponsor segment, \(adSpanLabel)"
    }
}
