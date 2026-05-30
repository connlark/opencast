import Foundation
import SwiftData

@Model
final class SubscriptionRecord {
    var feedURL: String = ""
    var title: String = ""
    var author: String?
    var artworkURL: String?
    var subscribedAt: Date = Date()
    var lastRefreshAt: Date?
    var isArchived: Bool = false
    var isVoiceBoostEnabled: Bool = true

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        artworkURL: String? = nil,
        subscribedAt: Date = Date(),
        lastRefreshAt: Date? = nil,
        isArchived: Bool = false,
        isVoiceBoostEnabled: Bool = true
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.subscribedAt = subscribedAt
        self.lastRefreshAt = lastRefreshAt
        self.isArchived = isArchived
        self.isVoiceBoostEnabled = isVoiceBoostEnabled
    }
}
