import AppIntents

@AppIntent(schema: .audio.playAudio)
struct PlayOpenCastAudioIntent: AudioPlaybackIntent {
    static let isAssistantOnly = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    var audioEntity: OpenCastAudioItem.Value
    var playbackAttributes: Set<OpenCastAudioPlaybackAttribute>
    var warmupAudioQueueResult: OpenCastAudioQueueResult?
    var queueLocation: OpenCastAudioQueueLocation?

    func perform() async throws -> some IntentResult {
        guard playbackAttributes.isEmpty, warmupAudioQueueResult == nil else {
            throw OpenCastSystemActionError.unsupportedPlaybackOptions
        }
        let action: OpenCastSystemAction
        switch audioEntity {
        case .episode(let episode):
            action = switch queueLocation {
            case .next: .enqueueNext(episode.id)
            case .tail: .enqueue(episode.id)
            case nil: .playEpisode(episode.id)
            }
        case .show(let show):
            guard queueLocation == nil else { throw OpenCastSystemActionError.unsupportedPlaybackOptions }
            action = .playLatest(show.id)
        }
        try await OpenCastIntentAccess.perform(action)
        return .result()
    }
}
