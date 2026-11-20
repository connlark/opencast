import AppIntents

nonisolated struct OpenCastAudioQueueResultQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [OpenCastAudioQueueResult] { [] }
    func entities(for identifiers: [String]) async throws -> [OpenCastAudioQueueResult] {
        // OpenCast issues no speculative warmup tokens, so no identifier resolves.
        []
    }
}
