import OpenCastTranscription
import SwiftUI

struct EpisodeTranscriptLineView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let segment: OpenCastTranscriptSegment
    let isActive: Bool
    let isCurrentEpisode: Bool
    let showsTimestamp: Bool
    let adSpanLabel: String?
    let isAdSpanStart: Bool
    let searchHighlightRanges: [Range<String.Index>]?
    let karaokeSpokenUpperBound: String.Index?
    let karaokeLayout: TranscriptKaraokeLayout?
    var adHighlight: TranscriptAdHighlight? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                if isAdSpanStart || adHighlight?.coverage == .unresolvedPartial, let adSpanLabel {
                    Label(adSpanLabel, systemImage: "megaphone")
                        .font(.caption)
                        .foregroundStyle(markerColor)
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
                if adSpanLabel != nil && adHighlight?.isWholeSegment != false {
                    Capsule()
                        .fill(markerColor)
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
                highlightRanges: searchHighlightRanges,
                adRanges: automaticWordRanges,
                uncertainAdRanges: uncertainWordRanges,
                differentiateWithoutColor: differentiateWithoutColor
            ))
        } else if searchHighlightRanges != nil || !automaticWordRanges.isEmpty || !uncertainWordRanges.isEmpty {
            Text(TranscriptLineTextBuilder.attributedText(
                text: segment.text,
                spokenUpperBound: nil,
                highlightRanges: searchHighlightRanges,
                adRanges: automaticWordRanges,
                uncertainAdRanges: uncertainWordRanges,
                differentiateWithoutColor: differentiateWithoutColor
            ))
        } else {
            Text(segment.text)
        }
    }

    private var isDimmed: Bool {
        isCurrentEpisode && !isActive
    }

    private var markerColor: Color {
        adHighlight?.isAutomaticSkip == false ? .orange.opacity(0.5) : .orange
    }

    private var automaticWordRanges: [Range<String.Index>] {
        adHighlight?.isAutomaticSkip == true ? (adHighlight?.ranges ?? []) : []
    }

    private var uncertainWordRanges: [Range<String.Index>] {
        guard let adHighlight else { return [] }
        return adHighlight.isAutomaticSkip ? adHighlight.uncertainRanges : adHighlight.ranges
    }

    private var accessibilityValueText: String {
        let timecode = segment.start.formattedPlaybackDuration
        guard let adSpanLabel else {
            return timecode
        }
        let extent: String
        if adHighlight?.isAutomaticSkip == false {
            extent = "Possible advertisement, not automatically skipped"
        } else {
            extent = adHighlight?.isWholeSegment == false ? "Partially skipped advertisement" : "Sponsor segment"
        }
        let precision = adHighlight?.coverage == .unresolvedPartial ? ", exact advertising words unavailable" : ""
        let uncertain = adHighlight?.hasUncertainCoverage == true && adHighlight?.isAutomaticSkip == true
            ? ", also contains possible advertising that is not automatically skipped" : ""
        return "\(timecode), \(extent), \(adSpanLabel)\(precision)\(uncertain)"
    }
}
