import Foundation

/// Per-section load state. `partial` shows the synchronously available rows
/// while a slower enrichment (file hashing, document loads, probes) is still
/// running; failures stay local to their section.
nonisolated enum EpisodeDiagnosticsSectionState: Sendable, Equatable {
    case loading
    case partial(EpisodeDiagnosticsSection)
    case loaded(EpisodeDiagnosticsSection)
    case failed(String)

    var section: EpisodeDiagnosticsSection? {
        switch self {
        case .partial(let section), .loaded(let section):
            section
        case .loading, .failed:
            nil
        }
    }

    var isSettled: Bool {
        switch self {
        case .loaded, .failed:
            true
        case .loading, .partial:
            false
        }
    }
}
