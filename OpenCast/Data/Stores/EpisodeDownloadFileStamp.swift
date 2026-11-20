import Foundation

/// Every completion stamps its record anew and moves a new file into place, so a replaced
/// download never reads the same, even at the same path and size.
nonisolated struct EpisodeDownloadFileStamp: Equatable, Sendable {
    let localRelativePath: String
    let completedAt: Date?
    let byteCount: Int64
    let modificationDate: Date?
}
