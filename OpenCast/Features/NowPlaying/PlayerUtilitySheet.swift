import Foundation

nonisolated enum PlayerUtilitySheet: String, Identifiable, Sendable {
    case speed
    case sleep
    case upNext
    case chapters
    case notes
    case transcript
    case soundLab

    var id: String { rawValue }

    nonisolated struct Handoff: Equatable, Sendable {
        nonisolated enum Action: Equatable, Sendable {
            case adFreePass
            case remoteTranscriptionEstimate
            case transcriptAction
        }

        let action: Action
        let episodeID: String?

        func action(
            isNowPlayingPresented: Bool,
            presentedSheet: PlayerUtilitySheet?,
            currentEpisodeID: String?
        ) -> Action? {
            guard isNowPlayingPresented, presentedSheet == nil, currentEpisodeID == episodeID else {
                return nil
            }
            return action
        }
    }
}
