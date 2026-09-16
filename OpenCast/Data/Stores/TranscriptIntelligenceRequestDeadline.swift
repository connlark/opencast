import Synchronization

/// Races one request against a wall-clock deadline. A PCC turn with tool
/// calling forced to `.required` hung past five minutes without ever raising
/// `LanguageModelError.timeout`, so the app owns the clock: the losing
/// request is cancelled and whatever it eventually produces is dropped.
enum TranscriptIntelligenceRequestDeadline {
    static let `default`: Duration = .seconds(60)

    static func run<Result: Sendable>(
        _ deadline: Duration,
        _ request: @escaping () async throws -> Result
    ) async throws -> Result {
        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            let resume: (Swift.Result<Result, any Error>) -> Void = { outcome in
                let isFirst = resumed.withLock { alreadyResumed in
                    defer { alreadyResumed = true }
                    return !alreadyResumed
                }
                if isFirst {
                    continuation.resume(with: outcome)
                }
            }
            let watchdog = Task {
                try await Task.sleep(for: deadline)
                resume(.failure(TranscriptIntelligenceFailure.timeout))
            }
            let work = Task {
                defer { watchdog.cancel() }
                do {
                    resume(.success(try await request()))
                } catch {
                    resume(.failure(error))
                }
            }
            Task {
                _ = try? await watchdog.value
                work.cancel()
            }
        }
    }
}
