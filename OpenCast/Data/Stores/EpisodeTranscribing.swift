protocol EpisodeTranscribing: Sendable {
    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>

    /// Drops the active service and any drain-retained runtime.
    func unload() async

    /// Leaves a drain-retained runtime in place and unloads everything else.
    func releaseRunResources() async

    func beginDrainRetention()
    func endDrainRetention() async
}

extension EpisodeTranscribing {
    func releaseRunResources() async {
        await unload()
    }

    func beginDrainRetention() {}
    func endDrainRetention() async {}
}
