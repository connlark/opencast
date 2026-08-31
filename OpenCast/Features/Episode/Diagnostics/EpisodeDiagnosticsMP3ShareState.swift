import Foundation

/// The Download & Share Audio flow: `waitingForDownload` covers the reused
/// foreground download; the presented share file itself lives on the model
/// as the activity-sheet item.
nonisolated enum EpisodeDiagnosticsMP3ShareState: Sendable, Equatable {
    case idle
    case waitingForDownload
    case failed(String)
}
