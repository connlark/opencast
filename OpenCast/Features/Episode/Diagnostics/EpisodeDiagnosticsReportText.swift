import Foundation

/// The copyable/shareable plain-text rendering of the diagnostics report;
/// unredacted by design and generated from the exact rows the sheet shows.
nonisolated enum EpisodeDiagnosticsReportText {
    static func make(
        episodeID: String,
        episodeTitle: String?,
        podcastTitle: String?,
        sections: [(id: EpisodeDiagnosticsSectionID, state: EpisodeDiagnosticsSectionState)]
    ) -> String {
        var lines = ["OpenCast Episode Diagnostics"]
        if let episodeTitle {
            let podcastSuffix = podcastTitle.map { " — \($0)" } ?? ""
            lines.append("Episode: \(episodeTitle)\(podcastSuffix)")
        }
        lines.append("Episode ID: \(episodeID)")

        for (id, state) in sections {
            lines.append("")
            lines.append("== \(id.title) ==")
            switch state {
            case .loading:
                lines.append("(still loading)")
            case .partial(let section):
                lines.append(contentsOf: sectionLines(section))
                lines.append("(some values still loading)")
            case .loaded(let section):
                lines.append(contentsOf: sectionLines(section))
            case .failed(let message):
                lines.append("(failed: \(message))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func sectionLines(_ section: EpisodeDiagnosticsSection) -> [String] {
        var lines = section.rows.map { "\($0.label): \($0.value)" }
        if let footnote = section.footnote {
            lines.append("Note: \(footnote)")
        }
        return lines
    }
}
