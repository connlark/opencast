import Testing
@testable import OpenCast

@Suite("Sound Lab remote transcription row model")
struct NowPlayingSoundLabRemoteTranscriptionRowModelTests {
    @Test("A completed transcript replaces the cloud action")
    func completedTranscriptShowsTranscript() {
        let model = NowPlayingSoundLabRemoteTranscriptionRowModel(
            hasCompletedTranscript: true,
            hasActiveRequest: true,
            isCurrentEpisodeRequest: true
        )

        #expect(model.action == .showTranscript)
        #expect(model.title == "Show Transcript")
        #expect(model.systemImage == "text.quote")
        #expect(model.phase == .completed)
        #expect(model.isEnabled)
        #expect(model.accessibilityValue == "Transcript available")
    }

    @Test("An active request for this episode disables the cloud action")
    func currentEpisodeRequestIsDisabled() {
        let model = NowPlayingSoundLabRemoteTranscriptionRowModel(
            hasCompletedTranscript: false,
            hasActiveRequest: true,
            isCurrentEpisodeRequest: true
        )

        #expect(model.action == .transcribe)
        #expect(model.title == "Transcribe Remotely")
        #expect(model.phase == .running)
        #expect(!model.isEnabled)
        #expect(model.accessibilityValue == "Remote transcription in progress")
    }

    @Test("An active request for another episode also disables the cloud action")
    func otherEpisodeRequestIsDisabled() {
        let model = NowPlayingSoundLabRemoteTranscriptionRowModel(
            hasCompletedTranscript: false,
            hasActiveRequest: true,
            isCurrentEpisodeRequest: false
        )

        #expect(model.action == .transcribe)
        #expect(!model.isEnabled)
        #expect(model.accessibilityValue == "Another remote transcription is in progress")
    }

    @Test("An episode without a transcript offers remote transcription")
    func episodeWithoutTranscriptCanTranscribe() {
        let model = NowPlayingSoundLabRemoteTranscriptionRowModel(
            hasCompletedTranscript: false,
            hasActiveRequest: false,
            isCurrentEpisodeRequest: false
        )

        #expect(model.action == .transcribe)
        #expect(model.title == "Transcribe Remotely")
        #expect(model.systemImage == "cloud")
        #expect(model.phase == .idle)
        #expect(model.isEnabled)
        #expect(model.accessibilityValue.isEmpty)
    }
}
