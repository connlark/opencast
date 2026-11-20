import Foundation

nonisolated protocol EpisodeDiagnosticsFileInspecting: Sendable {
    func fileInfo(at url: URL) async -> EpisodeDiagnosticsFileInfo
    func sha256(at url: URL) async throws -> String
    func audioDuration(at url: URL) async throws -> TimeInterval
}

/// A non-nil `errorDescription` is an access failure, not nonexistence: `exists` is then
/// unknown, not false.
nonisolated struct EpisodeDiagnosticsFileInfo: Sendable, Equatable {
    var exists: Bool
    var byteCount: Int64?
    var errorDescription: String?
}
