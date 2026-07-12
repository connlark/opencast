import SwiftUI

struct TranscriptAdAnalysisBanner: View {
    let state: EpisodeAdAnalysisJobState

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing Promos & Ads")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .failed(let record, let isStale):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    isStale ? EpisodeAdAnalysisControlsView.outdatedStatusTitle : "Promo/Ad Analysis Failed",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                if let message = record.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        case .completed(_, isStale: true):
            Label(EpisodeAdAnalysisControlsView.outdatedStatusTitle, systemImage: "megaphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        case .unavailable, .ready, .completed:
            EmptyView()
        }
    }
}
