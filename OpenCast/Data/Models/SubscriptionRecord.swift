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
    /// Unread, but production CloudKit fields can't be dropped and older builds still sync it.
    var isTranscriptAnalysisEnabled: Bool = false
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
    /// 0 follows the global speed. Read it through `PodcastPlaybackRateOverride`.
    var playbackRate: Double = 0
    /// Pocket Casts' raw values: 0 off, 1 bottom, 2 top. Read it through
    /// `UpNextAutoAddPosition(stored:)`.
    var autoAddToUpNext: Int = 0
    /// Never reassigned: duplicate repair keeps the smallest non-empty UUID on every device.
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
        playbackRate: Double = 0,
        autoAddToUpNext: Int = 0,
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
        self.playbackRate = playbackRate
        self.autoAddToUpNext = autoAddToUpNext
        self.dedupeUUID = dedupeUUID
    }
}
