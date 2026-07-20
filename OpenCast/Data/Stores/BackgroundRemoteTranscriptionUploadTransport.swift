import Foundation

/// Live upload transport: one background `URLSession` per job with a stable
/// identifier derived from the job ID, so uploads survive app suspension and
/// a relaunched process reconnects to still-running part tasks instead of
/// re-enqueuing them. Presigned URLs are plain PUTs — no header signing.
///
/// Thread safety: URLSession delivers delegate callbacks off-main; the
/// continuation registry is guarded by a lock and every continuation is
/// resolved exactly once (registry removal is the claim).
final class BackgroundRemoteTranscriptionUploadTransport: NSObject, RemoteTranscriptionUploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    private static let identifierPrefix = "com.connor.opencast.remote-transcription.upload."

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<RemoteTranscriptionUploadPartPutResult, any Error>] = [:]
    private var session: URLSession!

    nonisolated static func sessionIdentifier(jobID: String) -> String {
        identifierPrefix + jobID
    }

    init(jobID: String) {
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier(jobID: jobID)
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    nonisolated func uploadPart(
        partNumber: Int,
        fileURL: URL,
        to url: URL
    ) async throws -> RemoteTranscriptionUploadPartPutResult {
        if let adopted = await runningTask(for: partNumber) {
            return try await awaitCompletion(of: adopted, partNumber: partNumber)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = String(partNumber)
        return try await awaitCompletion(of: task, partNumber: partNumber)
    }

    nonisolated func cancelOutstandingTasks() async {
        let tasks = await session.allTasks
        for task in tasks {
            // Cancellation surfaces through didCompleteWithError, which
            // resolves any registered continuation by throwing.
            task.cancel()
        }
        session.invalidateAndCancel()
    }

    nonisolated func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    nonisolated private func runningTask(for partNumber: Int) async -> URLSessionTask? {
        let tasks = await session.allTasks
        return tasks.first { task in
            task.taskDescription == String(partNumber) && task.state != .canceling
        }
    }

    nonisolated private func awaitCompletion(
        of task: URLSessionTask,
        partNumber: Int
    ) async throws -> RemoteTranscriptionUploadPartPutResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation, partNumber: partNumber)
                if task.state == .completed {
                    // The task may have completed between discovery and
                    // registration; claim its response here so the
                    // continuation cannot hang.
                    resolve(partNumber: partNumber, task: task, error: task.error)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private func register(
        _ continuation: CheckedContinuation<RemoteTranscriptionUploadPartPutResult, any Error>,
        partNumber: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        continuations[partNumber] = continuation
    }

    nonisolated private func take(
        partNumber: Int
    ) -> CheckedContinuation<RemoteTranscriptionUploadPartPutResult, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.removeValue(forKey: partNumber)
    }

    nonisolated private func resolve(partNumber: Int, task: URLSessionTask, error: (any Error)?) {
        guard let continuation = take(partNumber: partNumber) else {
            return
        }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        let http = task.response as? HTTPURLResponse
        continuation.resume(
            returning: RemoteTranscriptionUploadPartPutResult(
                statusCode: http?.statusCode ?? -1,
                etag: http?.value(forHTTPHeaderField: "ETag")
            )
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let partNumber = task.taskDescription.flatMap(Int.init) else {
            return
        }
        resolve(partNumber: partNumber, task: task, error: error)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else {
            return
        }
        Task { @MainActor in
            RemoteTranscriptionUploadBackgroundEvents.shared.finishEvents(for: identifier)
        }
    }
}
