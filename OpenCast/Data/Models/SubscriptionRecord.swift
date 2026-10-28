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
    /// The show's own playback speed (CloudKit `CD_playbackRate`). 0 follows
    /// the global speed; read it through `PodcastPlaybackRateOverride`, which
    /// treats anything not finite and positive the same way.
    var playbackRate: Double = 0
    /// Auto Add to Up Next for the show (CloudKit `CD_autoAddToUpNext`) in
    /// Pocket Casts' raw values: 0 off, 1 bottom, 2 top. Read it through
    /// `UpNextAutoAddPosition(stored:)`, which treats any other value as off.
    var autoAddToUpNext: Int = 0
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
