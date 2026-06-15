import Foundation

nonisolated struct RefreshLogSnapshot: Identifiable, Equatable, Sendable {
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
