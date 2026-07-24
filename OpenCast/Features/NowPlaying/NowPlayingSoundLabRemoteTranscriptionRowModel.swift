import Foundation

nonisolated struct NowPlayingSoundLabRemoteTranscriptionRowModel: Equatable {
    let action: NowPlayingSoundLabRemoteTranscriptionAction
    let title: String
    let systemImage: String
    let phase: EpisodeAdFreePassPresentationPhase
    let isEnabled: Bool
    let accessibilityValue: String

    init(
        hasCompletedTranscript: Bool,
        hasActiveRequest: Bool,
        isCurrentEpisodeRequest: Bool
    ) {
        if hasCompletedTranscript {
            action = .showTranscript
            title = String(localized: "Show Transcript")
            systemImage = "text.quote"
            phase = .completed
            isEnabled = true
            accessibilityValue = String(localized: "Transcript available")
        } else {
            action = .transcribe
            title = String(localized: "Transcribe Remotely")
            systemImage = "cloud"
            phase = hasActiveRequest ? .running : .idle
            isEnabled = !hasActiveRequest
            accessibilityValue = if hasActiveRequest {
                isCurrentEpisodeRequest
                    ? String(localized: "Remote transcription in progress")
                    : String(localized: "Another remote transcription is in progress")
            } else {
                ""
            }
        }
    }
}
