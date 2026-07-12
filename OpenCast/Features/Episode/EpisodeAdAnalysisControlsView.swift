import SwiftUI

struct EpisodeAdAnalysisControlsView: View {
    /// Step-4 settled copy for any outdated analysis (transcript drift or a
    /// pre-`promo_ad_breaks_v2` policy) — shared with the Sound Lab panel.
    static let outdatedStatusTitle = "Outdated — run again"

    let state: EpisodeAdAnalysisJobState
    let document: EpisodeAdAnalysisDocument?
    let canAnalyze: Bool
    let lastErrorMessage: String?
    let onAnalyze: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .unavailable(let message):
                Label(message, systemImage: "megaphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .ready:
                analysisButton("Analyze Promos & Ads", systemImage: "megaphone", action: onAnalyze)
            case .running:
                ProgressView("Analyzing Promos & Ads")
                    .font(.footnote)
            case .completed(let record, let isStale):
                analysisSummary(record: record, isStale: isStale)
                completedActions(isStale: isStale)
            case .failed(let record, let isStale):
                EpisodeTranscriptionStatusMessageView(
                    title: isStale ? Self.outdatedStatusTitle : "Promo/Ad Analysis Failed",
                    message: record.errorMessage
                )
                failedActions()
            }

            if let lastErrorMessage, shouldShowLastError {
                EpisodeTranscriptionStatusMessageView(title: "Promo/Ad Analysis Issue", message: lastErrorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func completedActions(isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if canAnalyze {
                analysisButton(isStale ? "Analyze Promos & Ads" : "Reanalyze Promos & Ads", systemImage: "arrow.clockwise", action: onAnalyze)
            }
            analysisButton("Delete Promo/Ad Analysis", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private func failedActions() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if canAnalyze {
                analysisButton("Retry Promo/Ad Analysis", systemImage: "arrow.clockwise", action: onAnalyze)
            }
            analysisButton("Delete Promo/Ad Analysis", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private func analysisSummary(record: EpisodeAdAnalysisRecord, isStale: Bool) -> some View {
        let spanText = record.spanCount == 1 ? "1 promo span" : "\(record.spanCount) promo spans"
        VStack(alignment: .leading, spacing: 4) {
            Label(isStale ? Self.outdatedStatusTitle : spanText, systemImage: "megaphone")
                .font(.subheadline)
            if !isStale {
                Text(summaryDetail(record: record))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let document, !isStale, !document.spans.isEmpty {
                Text(document.spans.map(\.label).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func analysisButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
    }

    private func summaryDetail(record: EpisodeAdAnalysisRecord) -> String {
        var parts = [record.model, record.policy].filter { !$0.isEmpty }
        if record.warningCount > 0 {
            parts.append(record.warningCount == 1 ? "1 warning" : "\(record.warningCount) warnings")
        }
        return parts.joined(separator: " / ")
    }

    private var shouldShowLastError: Bool {
        switch state {
        case .failed:
            false
        case .unavailable, .ready, .running, .completed:
            true
        }
    }
}
