/// The only place the transcript disclosure appears, so it must run before the first generation.
enum TranscriptAnalysisGenerateDisclosureCopy {
    nonisolated static let title = "Generate Chapters & Summary?"
    nonisolated static let confirmButtonTitle = "Generate"

    nonisolated static func confirmationBody() -> String {
        var lines = [
            "This episode’s transcript text is sent to the AI provider you chose, using your key, to generate chapters and a summary. Without a key, it goes through opencast’s trial service. Your audio is never sent.",
            "Results are saved on this device."
        ]
        if TranscriptAnalysisFeatureFlags.chargesTranscriptionMinutes {
            lines.append("Uses transcription minutes.")
        }
        return lines.joined(separator: "\n")
    }
}
