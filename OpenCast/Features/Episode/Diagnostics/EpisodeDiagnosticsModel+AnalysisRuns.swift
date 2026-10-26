import Foundation
import OpenCastAnalysis

extension EpisodeDiagnosticsModel {
    func analysisRunsSection(appModel: OpenCastAppModel) -> EpisodeDiagnosticsSection {
        Self.analysisRunsSection(
            records: appModel.analysisRuns.records(limit: AnalysisRunsExport.maximumRuns),
            episodeID: episodeID
        )
    }

    /// The latest run of each feature for this episode, with the same fields
    /// as the Share Analysis Runs export: built from the run records only.
    nonisolated static func analysisRunsSection(
        records: [AnalysisRunRecord],
        episodeID: String
    ) -> EpisodeDiagnosticsSection {
        var rows: [(label: String, value: String)] = []
        for feature in AnalysisFeature.allCases {
            guard let record = records
                .filter({ $0.episodeID == episodeID && $0.feature == feature })
                .max(by: { $0.startedAt < $1.startedAt })
            else {
                continue
            }
            let entry = AnalysisRunsExportEntry(record)
            let prefix = featureTitle(feature)
            rows += [
                ("\(prefix) · Run ID", entry.runID),
                ("\(prefix) · Route", entry.route),
                ("\(prefix) · Provider", entry.provider),
                ("\(prefix) · Model", entry.modelID),
                ("\(prefix) · Bundle", "\(entry.bundleVersion)"),
                ("\(prefix) · Policy", "\(entry.policySource) \(entry.policyRevision)"),
                ("\(prefix) · State", entry.state),
                ("\(prefix) · Background", entry.background.map(EpisodeDiagnosticsFormatting.bool) ?? "—"),
                ("\(prefix) · Outcome", EpisodeDiagnosticsFormatting.value(entry.outcomeCode)),
                ("\(prefix) · Listener Failure", EpisodeDiagnosticsFormatting.value(entry.listenerFailure)),
                (
                    "\(prefix) · Windows",
                    "\(entry.windows.total) total, \(entry.windows.accepted) accepted, \(entry.windows.failed) failed"
                ),
                ("\(prefix) · Sends", "\(entry.sends)"),
                ("\(prefix) · Tokens", "in \(entry.inputTokens), out \(entry.outputTokens)"),
                ("\(prefix) · Paced", seconds(entry.pacedSeconds)),
                ("\(prefix) · Exchange", seconds(entry.exchangeSeconds)),
                ("\(prefix) · Started", EpisodeDiagnosticsFormatting.date(entry.startedAt)),
                ("\(prefix) · Finished", EpisodeDiagnosticsFormatting.date(entry.finishedAt)),
            ]
        }
        guard !rows.isEmpty else {
            return EpisodeDiagnosticsSection(rows: [("Status", "No analysis runs for this episode.")])
        }
        return EpisodeDiagnosticsSection(
            rows: rows,
            footnote: "Run records hold ids, outcomes and counts only; no transcript, key or address."
        )
    }

    private nonisolated static func featureTitle(_ feature: AnalysisFeature) -> String {
        switch feature {
        case .adDetection:
            "Ad Detection"
        case .chaptersSummary:
            "Chapters & Summary"
        }
    }

    private nonisolated static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }
}
