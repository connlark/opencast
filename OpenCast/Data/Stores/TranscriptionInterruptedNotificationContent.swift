struct TranscriptionInterruptedNotificationContent: Equatable {
    let title: String
    let body: String

    init(episodeTitle _: String?, restoredPriorTranscript: Bool) {
        if restoredPriorTranscript {
            title = "Transcript improvement stopped"
            body = "Improving only runs while OpenCast is open. Your existing transcript is unchanged."
        } else {
            title = "Transcription interrupted"
            body = "Apple transcription only runs while OpenCast is open. Open OpenCast and generate again — it starts over from the beginning."
        }
    }
}
