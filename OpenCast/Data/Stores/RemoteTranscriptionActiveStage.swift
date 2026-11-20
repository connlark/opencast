nonisolated enum RemoteTranscriptionActiveStage: Equatable {
    case checkingAudioDetails
    case transcribing
    case finalizing

    var displayText: String {
        switch self {
        case .checkingAudioDetails: "Checking audio details"
        case .transcribing: "Transcribing"
        case .finalizing: "Finalizing"
        }
    }
}
