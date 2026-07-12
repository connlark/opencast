import Foundation

nonisolated struct EpisodeDownloadResumeContext: Equatable, Sendable {
    let offset: Int64
    let entityTag: String?
    let lastModified: String?
}
