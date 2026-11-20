import Foundation
import SwiftData

/// Device-local: registered only in the local SwiftData configuration, never synced.
@Model
final class AdFreePassQueueItemRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var originRawValue: String = ""
    var enqueuedAt: Date = Date()
    var sequence: Int = 0
    /// Empty reads as on-device; older records carry no mode.
    var modeRawValue: String = ""
    /// A `RemoteTranscriptionJobExit` raw value: why a cloud item stopped polling while its
    /// server job kept running. Empty means not parked.
    var remoteParkReasonRawValue: String = ""

    init(
        episodeID: String,
        podcastID: String,
        originRawValue: String,
        enqueuedAt: Date = .now,
        sequence: Int,
        modeRawValue: String = "",
        remoteParkReasonRawValue: String = ""
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.originRawValue = originRawValue
        self.enqueuedAt = enqueuedAt
        self.sequence = sequence
        self.modeRawValue = modeRawValue
        self.remoteParkReasonRawValue = remoteParkReasonRawValue
    }
}
