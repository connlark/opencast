import Foundation

nonisolated struct RefreshLogSnapshot: Identifiable, Equatable, Sendable {
    /// Written as the log message when a refresh salvaged a partial feed from
    /// a document that failed to parse completely. The health UI matches this
    /// to present "partial" instead of a generic failure.
    static let partialFeedSalvageMessage =
        "Loaded a partial feed — part of the document could not be read."

    let refreshID: String
    let feedURL: String
    let startedAt: Date
    var finishedAt: Date?
    var errorMessage: String?

    init(
        refreshID: String = UUID().uuidString,
        feedURL: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.refreshID = refreshID
        self.feedURL = feedURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    var id: String {
        refreshID
    }
}
