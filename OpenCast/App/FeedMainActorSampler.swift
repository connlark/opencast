import Foundation
import Synchronization

/// Opt-in feed benchmark: measure delays in actually reaching the main actor.
/// Samples supplement the Instruments trace used for the release stall gate.
nonisolated final class FeedMainActorSampler: Sendable {
    private let maximumDelay = Mutex<Double>(0)
    private let samplingTask = Mutex<Task<Void, Never>?>(nil)

    func start() {
        samplingTask.withLock { $0 = Task { await self.sample() } }
    }

    func stop() async -> Double {
        let task = samplingTask.withLock { task in
            let result = task
            task = nil
            return result
        }
        task?.cancel()
        await task?.value
        return maximumDelay.withLock { $0 }
    }

    @concurrent
    private func sample() async {
        while !Task.isCancelled {
            let sent = ContinuousClock.now
            let received = await MainActor.run { ContinuousClock.now }
            let delay = sent.duration(to: received).components
            let seconds = Double(delay.seconds) + Double(delay.attoseconds) / 1e18
            maximumDelay.withLock { $0 = max($0, seconds) }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
