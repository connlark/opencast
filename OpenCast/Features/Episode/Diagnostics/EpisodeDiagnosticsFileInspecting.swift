import Foundation

/// File-system and media probes the diagnostics loader defers until the
/// sheet is actually open; injected so tests can prove nothing touches disk
/// before then.
nonisolated protocol EpisodeDiagnosticsFileInspecting: Sendable {
    func fileInfo(at url: URL) async -> EpisodeDiagnosticsFileInfo
    func sha256(at url: URL) async throws -> String
    func audioDuration(at url: URL) async throws -> TimeInterval
}

/// `errorDescription` carries an access failure (permissions, data
/// protection, I/O) that is *not* plain nonexistence; `exists` is then
/// unknown, not false.
nonisolated struct EpisodeDiagnosticsFileInfo: Sendable, Equatable {
    var exists: Bool
    var byteCount: Int64?
    var errorDescription: String?
}
