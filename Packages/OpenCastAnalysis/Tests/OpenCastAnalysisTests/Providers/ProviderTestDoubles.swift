import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Synchronization

/// Fixture keys of the real keys' shapes, assembled at run time so no
/// key-shaped literal sits in the source.
enum ProviderTestKeys {
    static let googleText = "AIza" + "Sy" + String(repeating: "Fx7", count: 11) + "q0"
    static let openAIText = "sk-" + "proj-" + String(repeating: "fXt9", count: 12)
    static let google = AnalysisProviderKey(googleText)!
    static let openAI = AnalysisProviderKey(openAIText)!
    static let all = [googleText, openAIText]

    /// Every fragment of `key` long enough to reach past the providers'
    /// public prefixes (`AIzaSy`, `sk-proj-`).
    static func fragments(of key: String, length: Int = 10) -> [String] {
        let characters = Array(key)
        guard characters.count >= length else { return [key] }
        return (0...(characters.count - length)).map { String(characters[$0..<($0 + length)]) }
    }

    /// Whether `text` holds any identifying fragment of either fixture key.
    static func leaks(in text: String) -> Bool {
        all.contains { key in fragments(of: key).contains { text.contains($0) } }
    }
}

/// An HTTP client the tests script: one result per send, in order.
final class ScriptedHTTPClient: AnalysisHTTPClient {
    enum Step: Sendable {
        case respond(AnalysisHTTPResponse)
        case fail(AnalysisHTTPFailure)
    }

    private let state: Mutex<(steps: [Step], requests: [AnalysisHTTPRequest], timeouts: [Double])>

    init(_ steps: [Step]) {
        state = Mutex((steps, [], []))
    }

    convenience init(status: Int, body: String, retryAfter: String? = nil) {
        self.init([.respond(AnalysisHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8)))])
    }

    var requests: [AnalysisHTTPRequest] { state.withLock { $0.requests } }
    var timeouts: [Double] { state.withLock { $0.timeouts } }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let step: Step? = state.withLock { state in
            state.requests.append(request)
            state.timeouts.append(timeoutSeconds)
            return state.steps.isEmpty ? nil : state.steps.removeFirst()
        }
        switch step {
        case .respond(let response)?:
            guard response.body.count <= maximumBodyBytes else { throw .oversizedBody }
            return response
        case .fail(let failure)?:
            throw failure
        case nil:
            throw .network
        }
    }
}

/// Collects redacted log lines.
final class CollectingLogSink: AnalysisLogSink {
    private let lines = Mutex<[String]>([])

    func write(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] { lines.withLock { $0 } }
}

/// A clock that moves only when the test advances it. Sleepers wake in
/// order of their wake time; cancellation wakes a sleeper with an error.
final class ManualClock: AnalysisClock {
    private struct Sleeper {
        var id: Int
        var wake: Double
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: Double, sleepers: [Sleeper], nextID: Int)>((0, [], 0))

    func now() -> Double { state.withLock { $0.now } }

    func sleep(seconds: Double) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Registration and the cancellation check share the lock the
                // cancellation handler takes, so a sleep cancelled before it
                // registers throws at once instead of waiting.
                enum Start { case wait, now, cancelled }
                let start: Start = state.withLock { state in
                    if Task.isCancelled { return .cancelled }
                    if seconds <= 0 { return .now }
                    state.sleepers.append(Sleeper(id: id, wake: state.now + seconds, continuation: continuation))
                    return .wait
                }
                switch start {
                case .wait: break
                case .now: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper that is due.
    func advance(by seconds: Double) {
        let due: [Sleeper] = state.withLock { state in
            state.now += seconds
            let due = state.sleepers.filter { $0.wake <= state.now }.sorted { $0.wake < $1.wake }
            state.sleepers.removeAll { $0.wake <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// When each sleeper wakes, in clock time.
    var wakeTimes: [Double] { state.withLock { $0.sleepers.map(\.wake) } }

    /// Waits until `count` tasks are asleep on this clock.
    func waitForSleepers(_ count: Int = 1) async {
        await eventually { sleeperCount >= count }
    }
}

/// An HTTP client whose sends wait until the test answers them, in order.
/// A cancelled send fails as a network error, as URLSession's does.
final class GatedHTTPClient: AnalysisHTTPClient {
    private struct Waiter {
        var id: Int
        var continuation: CheckedContinuation<ScriptedHTTPClient.Step, Never>
    }

    private let state = Mutex<(waiters: [Waiter], nextID: Int, sent: Int)>(([], 0, 0))

    var sentCount: Int { state.withLock { $0.sent } }
    var waitingCount: Int { state.withLock { $0.waiters.count } }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let id = state.withLock { state -> Int in
            state.sent += 1
            defer { state.nextID += 1 }
            return state.nextID
        }
        let step = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ScriptedHTTPClient.Step, Never>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(returning: .fail(.network)) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { state in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: .fail(.network))
        }
        switch step {
        case .respond(let response): return response
        case .fail(let failure): throw failure
        }
    }

    /// Answers the oldest waiting send.
    func answer(_ step: ScriptedHTTPClient.Step) {
        let waiter: Waiter? = state.withLock { state in
            state.waiters.isEmpty ? nil : state.waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: step)
    }

    func waitForWaiting(_ count: Int) async {
        await eventually { waitingCount >= count }
    }
}

/// Waits until `condition` holds: yields first, then polls every millisecond
/// of wall time, for at most `seconds`. A bounded count of yields is not
/// enough on a loaded machine, where the task the test waits for may not run
/// for many yields; a wait that gives up early lets the test move a manual
/// clock before a sleeper registers, and that sleeper then never wakes.
@discardableResult
func eventually(within seconds: Double = 60, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    var polls = 0
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        if polls < 100 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
        polls += 1
    }
    return true
}
