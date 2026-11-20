actor AnalysisServicesEnvironmentLookup {
    typealias Provider = @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    private let provider: Provider
    private var task: Task<RemoteTranscriptionStoreEnvironment, any Error>?

    init(provider: @escaping Provider) { self.provider = provider }

    func environment() async throws -> RemoteTranscriptionStoreEnvironment {
        if let task { return try await task.value }
        let task = Task { try await provider() }
        self.task = task
        return try await task.value
    }

    func cancel() { task?.cancel() }
}
