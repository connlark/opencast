import Foundation
import OpenCastAnalysisProviders
import Synchronization

/// The operation may keep unwinding after `run` returns: DeviceCheck ignores cancellation, and the
/// key's assertion gate stays held until that send is done, so no later send overtakes its counter.
nonisolated enum TrialProxyDeadline {
    static func run<Value: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = TrialProxyDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, seconds: seconds, operation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

private nonisolated final class TrialProxyDeadlineRace<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var finished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func start(
        _ continuation: CheckedContinuation<Value, any Error>,
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> Value
    ) {
        let alreadyFinished = state.withLock { state in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
            return
        }
        let work = Task {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            finish(.failure(AnalysisHTTPFailure.timeout))
        }
        let finishedMeanwhile = state.withLock { state in
            if state.finished { return true }
            state.tasks = [work, deadline]
            return false
        }
        if finishedMeanwhile {
            work.cancel()
            deadline.cancel()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        let (continuation, tasks) = state.withLock { state in
            guard !state.finished else { return (CheckedContinuation<Value, any Error>?.none, [Task<Void, Never>]()) }
            state.finished = true
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}
