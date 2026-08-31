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
    /// Retired Chapters & Summary per-show opt-in. Generation is a manual
    /// per-episode action now, so nothing reads this — but the field stays:
    /// `CD_isTranscriptAnalysisEnabled` is deployed in production CloudKit
    /// (prod fields can't be dropped) and older builds still sync it.
    var isTranscriptAnalysisEnabled: Bool = false
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
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
        isTranscriptAnalysisEnabled: Bool = false,
        skipIntroSeconds: Double = 0,
        skipOutroSeconds: Double = 0,
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
        self.isTranscriptAnalysisEnabled = isTranscriptAnalysisEnabled
        self.skipIntroSeconds = skipIntroSeconds
        self.skipOutroSeconds = skipOutroSeconds
        self.dedupeUUID = dedupeUUID
    }
}
