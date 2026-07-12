enum EpisodeTranscriptionRequestPhase: Equatable {
    case downloading
    case preparingWhisper
    case transcribingWhisper
    case transcribingAppleSpeech
    case completed
    case interrupted
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .cancelled, .failed:
            true
        case .downloading, .preparingWhisper, .transcribingWhisper, .transcribingAppleSpeech:
            false
        }
    }
}
