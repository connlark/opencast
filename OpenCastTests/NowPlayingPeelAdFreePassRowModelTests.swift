import Testing
@testable import OpenCast

@MainActor
@Suite("Peel ad-free row model")
struct NowPlayingPeelAdFreePassRowModelTests {
    @Test("Idle keeps the stable actionable title")
    func idleRow() {
        let row = NowPlayingPeelAdFreePassRowModel(presentation: .idle)

        #expect(row.title == "Skip Promos & Ads")
        #expect(row.isEnabled)
        #expect(row.emphasis == .normal)
        #expect(row.trailingSystemImage == "chevron.right")
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
            let row = NowPlayingPeelAdFreePassRowModel(presentation: presentation)
            #expect(row.title == "Skip Promos & Ads")
            #expect(!row.isEnabled)
            #expect(row.title != "Working...")
        }
    }

    @Test("Queued rows stay fixed-footprint with the stable title, not Queued")
    func queuedRowKeepsStableTitle() {
        let row = NowPlayingPeelAdFreePassRowModel(presentation: .queued(ahead: 2))

        #expect(row.title == "Skip Promos & Ads")
        #expect(!row.isEnabled)
        #expect(row.statusText == "Queued — 2 ahead")
    }

    @Test("Actionable stages keep their action words")
    func actionableStagesKeepActionWords() {
        #expect(NowPlayingPeelAdFreePassRowModel(presentation: .interrupted).title == "Resume")
        #expect(NowPlayingPeelAdFreePassRowModel(presentation: .failed("It broke.")).title == "Retry")
        #expect(NowPlayingPeelAdFreePassRowModel(presentation: .capDeferred).title == "Retry")
        #expect(NowPlayingPeelAdFreePassRowModel(presentation: .completed(zoneCount: 3)).title == "Reanalyze")
    }

    @Test("Trailing glyph and emphasis track the stage")
    func trailingGlyphAndEmphasis() {
        let transcribing = NowPlayingPeelAdFreePassRowModel(
            presentation: .transcribing(EpisodeTranscriptionProgress(
                audioDuration: 100,
                completedDuration: 25,
                checkpointCount: 0
            ))
        )
        let completed = NowPlayingPeelAdFreePassRowModel(presentation: .completed(zoneCount: 1))
        let failed = NowPlayingPeelAdFreePassRowModel(presentation: .failed("It broke."))
        let unavailable = NowPlayingPeelAdFreePassRowModel(presentation: .unavailable("No episode playing."))

        #expect(transcribing.trailingSystemImage == "hourglass")
        #expect(completed.trailingSystemImage == "checkmark.circle.fill")
        #expect(completed.emphasis == .completed)
        #expect(failed.trailingSystemImage == "arrow.clockwise")
        #expect(failed.emphasis == .failed)
        #expect(unavailable.emphasis == .unavailable)
    }

    @Test("The status text survives as the accessibility value")
    func statusTextCarriesToAccessibilityValue() {
        let row = NowPlayingPeelAdFreePassRowModel(presentation: .downloadingEpisode)

        #expect(row.statusText == "Downloading episode...")
    }

    @Test("Icon-only collapse triggers at tight widths and accessibility sizes")
    func iconOnlyCollapseRule() {
        #expect(NowPlayingPeelSettingsPanel.collapsesToIconOnly(rowAreaWidth: 120, isAccessibilitySize: false))
        #expect(NowPlayingPeelSettingsPanel.collapsesToIconOnly(rowAreaWidth: 200, isAccessibilitySize: true))
        #expect(!NowPlayingPeelSettingsPanel.collapsesToIconOnly(rowAreaWidth: 200, isAccessibilitySize: false))
    }
}
