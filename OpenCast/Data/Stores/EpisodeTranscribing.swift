protocol EpisodeTranscribing: Sendable {
    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    func unload() async
}
