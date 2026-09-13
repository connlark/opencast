import AppIntents

struct ResumeOpenCastPlaybackIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Resume Playback"
    nonisolated static let description = IntentDescription("Resume your current OpenCast episode at its saved position.")
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.resume)
        return .result()
    }
}
