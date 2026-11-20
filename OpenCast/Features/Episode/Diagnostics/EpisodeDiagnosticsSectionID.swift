import Foundation

/// Case order is the section order of both the sheet and the plain-text report.
nonisolated enum EpisodeDiagnosticsSectionID: String, CaseIterable, Identifiable, Sendable {
    case report
    case episode
    case progressAndSettings
    case playback
    case download
    case transcript
    case adAnalysis
    case adSpans
    case zoneMatrix
    case chaptersSummary
    case analysisRuns
    case feedProbe
    case enclosureProbe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .report:
            "Report"
        case .episode:
            "Episode"
        case .progressAndSettings:
            "Progress & Skip Settings"
        case .playback:
            "Playback"
        case .download:
            "Download"
        case .transcript:
            "Transcript"
        case .adAnalysis:
            "Ad Analysis"
        case .adSpans:
            "Ad Spans"
        case .zoneMatrix:
            "Zone Matrix"
        case .chaptersSummary:
            "Chapters & Summary"
        case .analysisRuns:
            "Analysis Runs"
        case .feedProbe:
            "Feed URL Probe"
        case .enclosureProbe:
            "Enclosure URL Probe"
        }
    }
}
