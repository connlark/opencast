import Testing
@testable import OpenCast

@MainActor
@Suite("Sound Lab ad-free row model")
struct NowPlayingSoundLabAdFreePassRowModelTests {
    @Test("Idle keeps the stable actionable title")
    func idleRow() {
        let row = NowPlayingSoundLabAdFreePassRowModel(presentation: .idle)

        #expect(row.title == "Skip Promos & Ads")
        #expect(row.isEnabled)
        #expect(row.emphasis == .normal)
        #expect(row.phase == .idle)
    }

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

    @Test("Queued rows stay fixed-footprint with the stable title, not Queued")
    func queuedRowKeepsStableTitle() {
        let row = NowPlayingSoundLabAdFreePassRowModel(presentation: .queued(ahead: 2))

        #expect(row.title == "Skip Promos & Ads")
        #expect(!row.isEnabled)
        #expect(row.statusText == "Queued — 2 ahead")
        #expect(row.phase == .queued)
    }

    @Test("Actionable stages keep their action words")
    func actionableStagesKeepActionWords() {
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .interrupted).title == "Resume")
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .failed("It broke.")).title == "Retry")
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .capDeferred).title == "Retry")
        #expect(NowPlayingSoundLabAdFreePassRowModel(presentation: .completed(zoneCount: 3)).title == "Reanalyze")
    }

    @Test("Typed phase and emphasis track every coarse presentation state")
    func typedPhaseAndEmphasis() {
        let transcribing = NowPlayingSoundLabAdFreePassRowModel(
            presentation: .transcribing(EpisodeTranscriptionProgress(
                audioDuration: 100,
                completedDuration: 25,
                checkpointCount: 0
            ))
        )
        let completed = NowPlayingSoundLabAdFreePassRowModel(presentation: .completed(zoneCount: 1))
        let failed = NowPlayingSoundLabAdFreePassRowModel(presentation: .failed("It broke."))
        let unavailable = NowPlayingSoundLabAdFreePassRowModel(presentation: .unavailable("No episode playing."))
        let deferred = NowPlayingSoundLabAdFreePassRowModel(presentation: .capDeferred)
        let checking = NowPlayingSoundLabAdFreePassRowModel(presentation: .checkingAnalysis)

        #expect(transcribing.phase == .running)
        #expect(completed.phase == .completed)
        #expect(completed.emphasis == .completed)
        #expect(failed.phase == .failed)
        #expect(failed.emphasis == .failed)
        #expect(unavailable.phase == .unavailable)
        #expect(unavailable.emphasis == .unavailable)
        #expect(deferred.phase == .deferred)
        #expect(checking.phase == .checking)
    }

    @Test("The status text survives as the accessibility value")
    func statusTextCarriesToAccessibilityValue() {
        let row = NowPlayingSoundLabAdFreePassRowModel(presentation: .downloadingEpisode)

        #expect(row.statusText == "Downloading episode...")
    }

    @Test("Icon-only collapse triggers at tight widths and accessibility sizes")
    func iconOnlyCollapseRule() {
        #expect(NowPlayingSoundLabPanel.collapsesToIconOnly(rowAreaWidth: 120, isAccessibilitySize: false))
        #expect(NowPlayingSoundLabPanel.collapsesToIconOnly(rowAreaWidth: 190, isAccessibilitySize: true))
        #expect(NowPlayingSoundLabPanel.collapsesToIconOnly(rowAreaWidth: 190, isAccessibilitySize: false))
        #expect(!NowPlayingSoundLabPanel.collapsesToIconOnly(rowAreaWidth: 200, isAccessibilitySize: false))
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
