import SwiftUI
import Testing
@testable import OpenCast

/// Below the panel's inline floor the Sound Lab is a case of the player's
/// utility sheet. A sheet action that opens another flow dismisses the sheet
/// first and hands the action to the player from the sheet's `onDismiss`.
@MainActor
@Suite("Sound Lab sheet: the handoff contract")
struct NowPlayingSoundLabSheetHandoffTests {
    @Test(
        "Once the sheet is gone the player runs the action for the episode it was made for",
        arguments: [
            PlayerUtilitySheet.Handoff.Action.adFreePass,
            .remoteTranscriptionEstimate,
            .transcriptAction
        ]
    )
    func runsOnceTheSheetIsGone(action: PlayerUtilitySheet.Handoff.Action) {
        let handoff = PlayerUtilitySheet.Handoff(action: action, episodeID: "episode-1")
        #expect(handoff.action(isNowPlayingPresented: true, presentedSheet: nil, currentEpisodeID: "episode-1") == action)
    }

    /// The transcript action's completion guard requires no utility sheet;
    /// the handoff runs only when none is up, so the fallback never blocks it.
    @Test(
        "It never runs under a sheet: the Sound Lab's own, or one opened meanwhile",
        arguments: [PlayerUtilitySheet.soundLab, .transcript, .upNext, .speed]
    )
    func neverRunsUnderASheet(sheet: PlayerUtilitySheet) {
        let handoff = PlayerUtilitySheet.Handoff(action: .transcriptAction, episodeID: "episode-1")
        #expect(handoff.action(isNowPlayingPresented: true, presentedSheet: sheet, currentEpisodeID: "episode-1") == nil)
    }

    @Test("It is dropped when the player was dismissed or playback moved to another episode")
    func droppedWhenStale() {
        let handoff = PlayerUtilitySheet.Handoff(action: .adFreePass, episodeID: "episode-1")
        #expect(handoff.action(isNowPlayingPresented: false, presentedSheet: nil, currentEpisodeID: "episode-1") == nil)
        #expect(handoff.action(isNowPlayingPresented: true, presentedSheet: nil, currentEpisodeID: "episode-2") == nil)
        #expect(handoff.action(isNowPlayingPresented: true, presentedSheet: nil, currentEpisodeID: nil) == nil)
    }

    @Test("The Sound Lab sheet shows no pane mode, so the pane beside the player stays drawn")
    func soundLabShowsNoPaneMode() {
        #expect(NowPlayingSecondaryPane(sheet: .soundLab) == nil)
        for selection in NowPlayingSecondaryPane.allCases {
            let presentation = NowPlayingSecondaryPaneTests.presentation(
                .split(band: NowPlayingSecondaryPaneTests.bookBand),
                selection,
                sheet: .soundLab
            )
            #expect(presentation.content == selection)
        }
        #expect(PlayerUtilitySheet.soundLab.id == "soundLab")
    }
}
