import Foundation
import SwiftData

@Model
final class RefreshLogRecord {
    var refreshID: String = UUID().uuidString
    var feedURL: String = ""
    var startedAt: Date = Date()
    var finishedAt: Date?
    var errorMessage: String?

    init(
        refreshID: String = UUID().uuidString,
        feedURL: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.refreshID = refreshID
        self.feedURL = feedURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }
}
