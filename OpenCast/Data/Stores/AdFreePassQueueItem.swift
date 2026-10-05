import Foundation

struct AdFreePassQueueItem: Identifiable, Equatable {
    let episode: EpisodeListItemSnapshot
    let origin: AdFreePassQueueOrigin
    let enqueuedAt: Date
    let sequence: Int
    let mode: AdDetectionMode
    /// Set while a cloud item waits at the head after its drain stopped
    /// polling; the server job keeps running and Resume re-attaches it.
    var remoteParkReason: RemoteTranscriptionJobExit?

    init(
        episode: EpisodeListItemSnapshot,
        origin: AdFreePassQueueOrigin,
        enqueuedAt: Date,
        sequence: Int,
        mode: AdDetectionMode = .onDevice,
        remoteParkReason: RemoteTranscriptionJobExit? = nil
    ) {
        self.episode = episode
        self.origin = origin
        self.enqueuedAt = enqueuedAt
        self.sequence = sequence
        self.mode = mode
        self.remoteParkReason = remoteParkReason
    }

    var id: String {
        episode.episodeID
    }

    var episodeID: String {
        episode.episodeID
    }
}
