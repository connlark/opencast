import Foundation

struct EpisodeTranscriptionRequest: Identifiable, Equatable {
    let id: UUID
    let episodeID: String
    let episodeTitle: String
    var phase: EpisodeTranscriptionRequestPhase
    var canResumeFromCheckpoint: Bool

    init(
        id: UUID = UUID(),
        episodeID: String,
        episodeTitle: String,
        phase: EpisodeTranscriptionRequestPhase,
        canResumeFromCheckpoint: Bool = false
    ) {
        self.id = id
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.phase = phase
        self.canResumeFromCheckpoint = canResumeFromCheckpoint
    }
}
