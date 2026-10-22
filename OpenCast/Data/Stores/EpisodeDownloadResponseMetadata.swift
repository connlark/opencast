import Foundation

nonisolated struct EpisodeDownloadResponseMetadata: Equatable, Sendable {
    let entityTag: String?
    let lastModified: String?
    /// The Content-Disposition filename; nil when the response sent no such
    /// header, because Foundation otherwise invents one from the URL.
    let suggestedFilename: String?
    let mimeType: String?

    init(
        entityTag: String?,
        lastModified: String?,
        suggestedFilename: String? = nil,
        mimeType: String? = nil
    ) {
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
    }
}
