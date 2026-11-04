import Foundation

nonisolated enum PlayerUtilitySheet: String, Identifiable, Sendable {
    case speed
    case sleep
    case upNext
    case chapters
    case notes
    case transcript
    /// The Sound Lab's controls where the artwork is below the panel's
    /// inline floor.
    case soundLab

    var id: String { rawValue }

    /// An action a sheet hands to the player once the sheet is gone, so the
    /// flow it opens (another sheet, a dialog, the key notice) presents from
    /// a player with nothing over it.
    nonisolated struct Handoff: Equatable, Sendable {
        nonisolated enum Action: Equatable, Sendable {
            case adFreePass
            case remoteTranscriptionEstimate
            case transcriptAction
        }

        let action: Action
        let episodeID: String?

        /// The action, if it still applies: the player is up with no sheet
        /// over it and still on the episode the tap was made for.
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
