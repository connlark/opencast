import Foundation

nonisolated struct EpisodeDownloadResponseMetadata: Equatable, Sendable {
    let entityTag: String?
    let lastModified: String?
}
