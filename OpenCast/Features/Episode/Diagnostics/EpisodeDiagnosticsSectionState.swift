import Foundation

/// No error case: errors fold into ordinary rows, so a section never goes dark.
nonisolated enum EpisodeDiagnosticsSectionState: Sendable, Equatable {
    case loading
    case partial(EpisodeDiagnosticsSection)
    case loaded(EpisodeDiagnosticsSection)

    var section: EpisodeDiagnosticsSection? {
        switch self {
        case .partial(let section), .loaded(let section):
            section
        case .loading:
            nil
        }
    }
}
