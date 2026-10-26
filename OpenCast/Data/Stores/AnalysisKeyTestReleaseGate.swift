import Foundation
import Synchronization

/// Under UI testing, holds each key test until the UI test releases it by
/// posting the Darwin notification `releaseName(call:)` (call 1 is the
/// first test of the launch), so a test decides when an older request
/// finishes: after a newer one, or after its sheet closed. A held request
/// ignores cancellation and still answers, late, as a slow provider would.
nonisolated final class AnalysisKeyTestReleaseGate: Sendable {
    static let namePrefix = "com.connor.opencast.ui-testing.release-analysis-key-test."

    static func releaseName(call: Int) -> String {
        namePrefix + String(call)
    }

    private struct State {
        var released: Set<Int> = []
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    /// Listens for the releases of calls `1...calls`; the gate lives for the
    /// process (the notification center holds it).
    init(calls: Int = 8) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passRetained(self).toOpaque()
        for call in 1...max(calls, 1) {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else {
                        return
                    }
                    let gate = Unmanaged<AnalysisKeyTestReleaseGate>.fromOpaque(observer).takeUnretainedValue()
                    gate.release(named: name.rawValue as String)
                },
                Self.releaseName(call: call) as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    /// Returns once `call` is released, at once if it already was.
    func wait(call: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let releasedAlready = state.withLock { state -> Bool in
                if state.released.contains(call) {
                    return true
                }
                state.waiting[call] = continuation
                return false
            }
            if releasedAlready {
                continuation.resume()
            }
        }
    }

    func release(call: Int) {
        let continuation = state.withLock { state in
            state.released.insert(call)
            return state.waiting.removeValue(forKey: call)
        }
        continuation?.resume()
    }

    private func release(named name: String) {
        guard name.hasPrefix(Self.namePrefix), let call = Int(name.dropFirst(Self.namePrefix.count)) else {
            return
        }
        release(call: call)
    }
}
