import Foundation

nonisolated enum EpisodeDiagnosticsMP3ShareState: Sendable, Equatable {
    case idle
    case waitingForDownload
    case failed(String)
}
