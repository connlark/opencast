import OpenCastAnalysis

/// How a request left a pacer's queue.
public enum AnalysisPacerAdmission: Sendable, Hashable {
    /// Admitted after waiting `waitedSeconds`; the caller must call
    /// ``AnalysisKeyPacer/release()`` when its exchange ends.
    case admitted(waitedSeconds: Double)
    /// The request's deadline would pass before the key could take it.
    case deadlinePassed
    case cancelled
}

/// Admission control for one provider key. Up to `maxInFlight` requests
/// run at once until the provider first answers 429 (a rate limit, not a
/// hard quota) on the key; from then on, for as long as the pacer lives,
/// requests go one at a time and none starts before the latest
/// `Retry-After` has passed. Pacing never decides an outcome: a request
/// that cannot be admitted before its deadline fails as a timeout, and the
/// run budget still bounds the episode.
public actor AnalysisKeyPacer {
    /// The concurrent admissions allowed before the first rate limit,
    /// clamped to 1...4.
    public nonisolated let maxInFlight: Int
    private let clock: any AnalysisClock
    private var serial = false
    private var notBefore = -Double.infinity
    private var inFlight = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiterID = 0

    public init(maxInFlight: Int, clock: any AnalysisClock) {
        self.maxInFlight = min(max(maxInFlight, 1), 4)
        self.clock = clock
    }

    /// Whether the key has been rate limited and now runs serially.
    public var isSerial: Bool { serial }

    /// The concurrent admissions allowed now.
    public var admissionLimit: Int { serial ? 1 : maxInFlight }

    /// Waits until the key may take another request: a free slot and, once
    /// rate limited, the end of the last `Retry-After`. `deadline` is a
    /// time on the pacer's clock.
    public func admit(deadline: Double) async -> AnalysisPacerAdmission {
        let start = clock.now()
        let admission = await admission(deadline: deadline)
        if case .admitted = admission {
            return .admitted(waitedSeconds: max(clock.now() - start, 0))
        }
        // A request leaving without the slot it may have been woken for
        // passes the wake-up on, so no waiter sleeps beside a free slot.
        wakeNextWaiter()
        return admission
    }

    private func admission(deadline: Double) async -> AnalysisPacerAdmission {
        while true {
            if Task.isCancelled { return .cancelled }
            let now = clock.now()
            if now >= deadline { return .deadlinePassed }
            if inFlight >= admissionLimit {
                guard await waitForSlot(until: deadline) else {
                    return Task.isCancelled ? .cancelled : .deadlinePassed
                }
                continue
            }
            if now < notBefore {
                guard notBefore < deadline else { return .deadlinePassed }
                do {
                    try await clock.sleep(seconds: notBefore - now)
                } catch {
                    return .cancelled
                }
                continue
            }
            inFlight += 1
            return .admitted(waitedSeconds: 0)
        }
    }

    /// Ends one admitted request's hold on the key. A request the provider
    /// rate-limited passes `rateLimited`, which takes effect before any
    /// waiter can be admitted: serial from now on, and no admission before
    /// `retryAfterSeconds` (already capped by the classifier) passes.
    public func release(rateLimited: Bool = false, retryAfterSeconds: Int? = nil) {
        if rateLimited {
            serial = true
            if let retryAfterSeconds {
                notBefore = max(notBefore, clock.now() + Double(max(retryAfterSeconds, 0)))
            }
        }
        inFlight = max(inFlight - 1, 0)
        wakeNextWaiter()
    }

    /// Records a rate-limit answer outside an admitted request.
    public func noteRateLimited(retryAfterSeconds: Int?) {
        serial = true
        if let retryAfterSeconds {
            notBefore = max(notBefore, clock.now() + Double(max(retryAfterSeconds, 0)))
        }
    }

    /// Suspends until a release wakes this waiter (`true`) or the deadline
    /// passes or the task is cancelled first (`false`).
    private func waitForSlot(until deadline: Double) async -> Bool {
        let id = nextWaiterID
        nextWaiterID += 1
        let delay = deadline - clock.now()
        let clock = clock
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                return
            }
            await self?.expireWaiter(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { [weak self] in await self?.expireWaiter(id) }
        }
    }

    private func expireWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func wakeNextWaiter() {
        guard inFlight < admissionLimit, !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume(returning: true)
    }
}
