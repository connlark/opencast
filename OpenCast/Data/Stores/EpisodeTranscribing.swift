protocol EpisodeTranscribing: Sendable {
    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>

    /// Hard unload: drops the active service and any drain-retained runtime.
    func unload() async

    /// End-of-item release after a successful run: leaves a drain-retained
    /// runtime in place, unloads everything else.
    func releaseRunResources() async

    /// Drain-scoped model retention (whisper-perf E1). Only the ad-free-pass
    /// queue coordinator opens a retention window; outside one, every item
    /// unloads its runtime as before.
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
