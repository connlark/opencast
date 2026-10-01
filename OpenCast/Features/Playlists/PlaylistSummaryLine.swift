import SwiftUI

/// A collection row's or tile's size line. A smart playlist reads its
/// evaluation here and nowhere else in the collection, so only visible rows
/// and tiles evaluate, and the collection's body observes no smart-list
/// dependencies. Callers set the font, style and line limit; only the smart
/// glyph carries the playlist's tint.
struct PlaylistSummaryLine: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let summary: PlaylistSummary

    var body: some View {
        switch summary.kind {
        case .manual:
            PlaylistSummaryText(itemCount: summary.itemCount, totalDuration: summary.totalDuration)
        case .smart:
            smartLine
        }
    }

    private var smartLine: some View {
        let evaluation = appModel.smartPlaylistEvaluation(for: summary)
        let glyph = Text(Image(systemName: "sparkles"))
            .foregroundStyle((summary.tint ?? .blue).color)
        let line = PlaylistSummaryText.smartLine(itemCount: evaluation.count, totalDuration: evaluation.totalDuration)

        return Text("\(glyph) Smart · \(line)")
            .accessibilityLabel(
                PlaylistSummaryText.smartSpokenLine(itemCount: evaluation.count, totalDuration: evaluation.totalDuration)
            )
    }
}
