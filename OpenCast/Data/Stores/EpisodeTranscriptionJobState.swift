enum EpisodeTranscriptionJobState: Equatable {
    case unavailable
    case downloadRequired
    case modelRequired
    case modelBusy
    case ready
    case running(EpisodeTranscriptionProgress)
    case completed(EpisodeTranscriptRecord)
    case failed(EpisodeTranscriptRecord)
    case cancelled(EpisodeTranscriptRecord)
    case interrupted(EpisodeTranscriptRecord)
}
