import Foundation
import SwiftData

/// Device-local persistence for pending ad-free pass queue items. Never
/// synced; registered only in the local SwiftData configuration.
@Model
final class AdFreePassQueueItemRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var originRawValue: String = ""
    var enqueuedAt: Date = Date()
    var sequence: Int = 0
    /// Empty on records persisted before cloud detect existed ⇒ on-device.
    var modeRawValue: String = ""
    /// Why a cloud item stopped polling while its server job kept running
    /// (`RemoteTranscriptionJobExit` raw value). Empty ⇒ not parked.
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
