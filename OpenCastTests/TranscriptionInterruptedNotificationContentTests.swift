import Testing
@testable import OpenCast

@MainActor
@Suite("Transcription interruption notification content")
struct TranscriptionInterruptedNotificationContentTests {
    @Test("Generate interruption explains that Apple Speech restarts")
    func generateInterruptionCopy() {
        let content = TranscriptionInterruptedNotificationContent(
            episodeTitle: "Episode",
            restoredPriorTranscript: false
        )

        #expect(content.title == "Transcription interrupted")
        #expect(content.body == "Apple transcription only runs while OpenCast is open. Open OpenCast and generate again — it starts over from the beginning.")
    }

    @Test("Improve interruption confirms the existing transcript is unchanged")
    func improveInterruptionCopy() {
        let content = TranscriptionInterruptedNotificationContent(
            episodeTitle: nil,
            restoredPriorTranscript: true
        )

        #expect(content.title == "Transcript improvement stopped")
        #expect(content.body == "Improving only runs while OpenCast is open. Your existing transcript is unchanged.")
    }
}
