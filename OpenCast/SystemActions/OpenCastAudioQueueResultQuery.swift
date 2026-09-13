import AppIntents

nonisolated struct OpenCastAudioQueueResultQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [OpenCastAudioQueueResult] { [] }
    func entities(for identifiers: [String]) async throws -> [OpenCastAudioQueueResult] {
        // OpenCast does not issue speculative warmup tokens in this pass.
        []
    }
}
