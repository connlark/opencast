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
    var isAdAutoDetectEnabled: Bool = false
    /// Stable per-record identity so duplicate repair picks the same winner on
    /// every device (smallest UUID wins); peers that chose opposite winners
    /// used to cross-delete both copies. Records imported from builds that
    /// predate the field carry "".
    var dedupeUUID: String = ""

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        artworkURL: String? = nil,
        subscribedAt: Date = Date(),
        lastRefreshAt: Date? = nil,
        isArchived: Bool = false,
        isVoiceBoostEnabled: Bool = true,
        isAdAutoDetectEnabled: Bool = false,
        dedupeUUID: String = UUID().uuidString
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.subscribedAt = subscribedAt
        self.lastRefreshAt = lastRefreshAt
        self.isArchived = isArchived
        self.isVoiceBoostEnabled = isVoiceBoostEnabled
        self.isAdAutoDetectEnabled = isAdAutoDetectEnabled
        self.dedupeUUID = dedupeUUID
    }
}
