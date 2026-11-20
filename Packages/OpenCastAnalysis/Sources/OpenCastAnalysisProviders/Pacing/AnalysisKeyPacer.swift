import OpenCastAnalysis

public enum AnalysisPacerAdmission: Sendable, Hashable {
    /// The caller must call `release` when its exchange ends.
    case admitted(waitedSeconds: Double)
    case deadlinePassed
    case cancelled
}

/// After the key's first 429 (a rate limit, not a hard quota), requests go one at a time for the
/// pacer's life, none before the latest `Retry-After` has passed.
public actor AnalysisKeyPacer {
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

    public var isSerial: Bool { serial }

    public var admissionLimit: Int { serial ? 1 : maxInFlight }

    /// `deadline` is an absolute time on the pacer's clock.
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

    /// `rateLimited` takes effect before any waiter is woken.
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

    /// `true` when a release wakes this waiter; `false` on deadline or cancellation.
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
