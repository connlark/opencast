import Foundation

/// Fixed identity and ordering for every diagnostics section; the sheet and
/// the plain-text report both iterate `allCases`.
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
        case .feedProbe:
            "Feed URL Probe"
        case .enclosureProbe:
            "Enclosure URL Probe"
        }
    }
}
