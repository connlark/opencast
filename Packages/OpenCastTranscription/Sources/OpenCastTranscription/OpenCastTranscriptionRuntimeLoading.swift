protocol OpenCastTranscriptionRuntimeLoading: Sendable {
    func loadRuntime(for location: OpenCastWhisperModelLocation) async throws -> any OpenCastTranscriptionRuntime
}
