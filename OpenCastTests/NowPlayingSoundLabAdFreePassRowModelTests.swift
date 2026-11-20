import Testing
@testable import OpenCast

@MainActor
@Suite("Sound Lab ad-free row model")
struct NowPlayingSoundLabAdFreePassRowModelTests {
    @Test("In-flight stages never surface progress text or Working as the title")
    func inFlightStagesKeepStableTitle() {
        let inFlight: [EpisodeAdFreePassPresentation] = [
            .downloadingEpisode,
            .installingSpeechAssets(fractionCompleted: 0.4),
            .transcribing(EpisodeTranscriptionProgress(
                audioDuration: 100,
                completedDuration: 25,
                checkpointCount: 1
            )),
            .analyzing,
            .checkingModel
        ]

        for presentation in inFlight {
            let row = NowPlayingSoundLabAdFreePassRowModel(presentation: presentation)
            #expect(row.title == "Skip Promos & Ads")
            #expect(!row.isEnabled)
            #expect(row.title != "Working...")
        }
    }

    @Test("Actionable stages keep their action words")
    func actionableStagesKeepActionWords() {
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .interrupted).title == "Resume")
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .failed("It broke.")).title == "Retry")
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .completed(zoneCount: 3)).title == "Reanalyze")
    }

    @Test("A detached analysis offers Detect Ads Again, enabled, with the page's caption as its value")
    func detachedRowOffersDetectAdsAgain() {
        let row = NowPlayingSoundLabAdFreePassRowModel(presentation: .detached)

        #expect(row.title == "Detect Ads Again")
        #expect(row.isEnabled)
        #expect(row.phase == .idle)
        #expect(row.emphasis == .normal)
        #expect(row.statusText == "Ad skips unavailable for this audio. Detect Ads Again to restore them.")
        #expect(row.statusText == EpisodeAdSpanTimelineView.detachedCaption)
        #expect(NowPlayingSoundLabLayout.fixedActionTitles.contains { $0.title == row.title })
    }

    @Test("Artwork rail derives from panel geometry and preserves default text space")
    func artworkRailLayoutRule() {
        let phoneLayout = NowPlayingSoundLabLayout(panelWidth: 300)
        let compactLayout = NowPlayingSoundLabLayout(panelWidth: 240)

        #expect(phoneLayout.artworkRailWidth >= 40)
        #expect(phoneLayout.artworkRailWidth <= 54)
        #expect(phoneLayout.rowAreaWidth >= NowPlayingSoundLabLayout.iconOnlyRowAreaWidth)
        #expect(compactLayout.rowAreaWidth < NowPlayingSoundLabLayout.iconOnlyRowAreaWidth)
        #expect(NowPlayingSoundLabLayout.controlRowHeight >= 44)
    }
}
