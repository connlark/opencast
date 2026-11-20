import Foundation
import OpenCastAnalysis

public enum AnalysisExecutionResult: Sendable, Hashable {
    /// `background`: a continued-processing card held the run.
    case finished(AnalysisOutcome, background: Bool)
    /// The system, or the listener from the card, ended the task and cancelled the run.
    case expired
}

/// The card's progress moves on every tick, at most a minute apart, so the system never sees
/// a stalled task while a long provider call is in flight.
@MainActor
public final class AnalysisExecutionSession {
    public enum State: Sendable, Hashable {
        case idle
        case submitted
        case running
        case foregroundOnly
    }

    public nonisolated static let maxTickInterval: Duration = .seconds(60)
    public nonisolated static let minimumUnitCount: Int64 = 1_000

    public let identifier: String
    public let title: String
    public private(set) var state: State = .idle

    private let scheduler: any AnalysisContinuedTaskScheduling
    private weak var arbiter: (any AnalysisContinuedTaskArbiter)?
    private let tickInterval: Duration
    private let clock: any AnalysisClock

    private var hasRegisteredLaunchHandler = false
    private var handle: (any AnalysisContinuedTaskHandle)?
    private var heldByCard = false
    private var expired = false
    private var runSequence = 0
    private var subtitle = ""
    private var expectedSeconds = 1.0
    private var startedAt = 0.0
    private var scale = AnalysisExecutionSession.ProgressScale(expectedSeconds: 1, tickSeconds: 1)
    private var units: Int64 = 0
    private var work: Task<AnalysisOutcome, Never>?
    private var ticker: Task<Void, Never>?

    public init(
        identifier: String,
        title: String,
        scheduler: any AnalysisContinuedTaskScheduling,
        arbiter: (any AnalysisContinuedTaskArbiter)?,
        tickInterval: Duration = .seconds(2),
        clock: any AnalysisClock = AnalysisSystemClock()
    ) {
        self.identifier = identifier
        self.title = title
        self.scheduler = scheduler
        self.arbiter = arbiter
        self.tickInterval = min(max(tickInterval, .milliseconds(100)), Self.maxTickInterval)
        self.clock = clock
    }

    public var isArmed: Bool { state == .submitted || state == .running }

    public var isProtectingBackgroundExecution: Bool { state == .running && handle != nil }

    public func run(
        subtitle: String,
        expectedSeconds: Int,
        _ work: @escaping @Sendable () async -> AnalysisOutcome
    ) async -> AnalysisExecutionResult {
        guard self.work == nil else {
            return .finished(await Self.perform(work), background: false)
        }
        runSequence += 1
        expired = false
        heldByCard = false
        self.subtitle = subtitle
        self.expectedSeconds = Double(max(expectedSeconds, 1))
        startedAt = clock.now()
        scale = ProgressScale(expectedSeconds: self.expectedSeconds, tickSeconds: tickSeconds)
        units = scale.start
        let task = Task { await Self.perform(work) }
        self.work = task
        let outcome = await withTaskCancellationHandler {
            await arm()
            return await task.value
        } onCancel: {
            task.cancel()
        }
        self.work = nil
        let wasExpired = expired
        let background = heldByCard
        finish(success: !wasExpired && outcome.isSuccess)
        return wasExpired ? .expired : .finished(outcome, background: background)
    }

    @concurrent
    private static func perform(_ work: @escaping @Sendable () async -> AnalysisOutcome) async -> AnalysisOutcome {
        await work()
    }

    private func arm() async {
        guard arbiter?.mayArm(identifier: identifier) ?? true else {
            state = .foregroundOnly
            return
        }
        guard registerLaunchHandlerIfNeeded() else {
            state = .foregroundOnly
            return
        }
        scheduler.cancel(identifier: identifier)
        // Submitted before the request is sent: the system may launch it
        // while the submission is still returning.
        state = .submitted
        do {
            try await scheduler.submit(identifier: identifier, title: title, subtitle: subtitle)
        } catch {
            if state == .submitted { state = .foregroundOnly }
        }
    }

    private func registerLaunchHandlerIfNeeded() -> Bool {
        guard !hasRegisteredLaunchHandler else { return true }
        hasRegisteredLaunchHandler = scheduler.registerLaunchHandler(identifier: identifier) { [weak self] handle in
            self?.handleLaunch(handle)
        }
        return hasRegisteredLaunchHandler
    }

    private func handleLaunch(_ launched: any AnalysisContinuedTaskHandle) {
        guard state == .submitted, work != nil else {
            launched.setTaskCompleted(success: false)
            return
        }
        handle = launched
        heldByCard = true
        state = .running
        let sequence = runSequence
        launched.setExpirationHandler { [weak self] in
            Task { @MainActor [weak self] in self?.expire(sequence) }
        }
        launched.progress.totalUnitCount = scale.total
        launched.progress.completedUnitCount = units
        launched.updateTitle(title, subtitle: subtitle)
        startTicking()
    }

    private var tickSeconds: Double {
        Double(tickInterval.components.seconds) + Double(tickInterval.components.attoseconds) * 1e-18
    }

    private func startTicking() {
        ticker?.cancel()
        let seconds = tickSeconds
        let clock = clock
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(seconds: seconds)
                } catch {
                    return
                }
                self?.tick()
            }
        }
    }

    func tick() {
        guard let handle, state == .running else { return }
        units = scale.units(after: max(clock.now() - startedAt, 0), previous: units)
        handle.progress.completedUnitCount = units
    }

    /// Twenty units per expected tick: the creep moves the card every tick, and the one-unit
    /// floor past the 90 % ceiling lasts twice the expected run again.
    struct ProgressScale: Equatable {
        let total: Int64
        let start: Int64
        let ceiling: Int64
        let expectedSeconds: Double

        init(expectedSeconds: Double, tickSeconds: Double) {
            // Bounded before the conversion, so no run length or tick traps.
            let limit = Double(Int64.max / 40)
            let ratio = (expectedSeconds / max(tickSeconds, 0.001)).rounded(.up)
            let ticks = ratio.isNaN ? 1 : Int64(min(max(ratio, 1), limit))
            total = max(AnalysisExecutionSession.minimumUnitCount, ticks * 20)
            start = total / 100
            ceiling = total / 100 * 90
            self.expectedSeconds = expectedSeconds
        }

        func units(after elapsed: Double, previous: Int64) -> Int64 {
            let ratio = elapsed / expectedSeconds
            let fraction = ratio.isNaN ? 0 : min(max(ratio, 0), 1)
            let linear = start + Int64((Double(ceiling - start) * fraction).rounded(.down))
            return min(max(linear, previous + 1), total - 1)
        }
    }

    private func expire(_ sequence: Int) {
        guard sequence == runSequence, work != nil else { return }
        expired = true
        work?.cancel()
        complete(success: false)
    }

    private func finish(success: Bool) {
        if handle != nil {
            complete(success: success)
        } else if state == .submitted {
            scheduler.cancel(identifier: identifier)
        }
        ticker?.cancel()
        ticker = nil
        handle = nil
        state = .idle
    }

    private func complete(success: Bool) {
        ticker?.cancel()
        ticker = nil
        guard let handle else { return }
        self.handle = nil
        if success {
            handle.progress.completedUnitCount = handle.progress.totalUnitCount
        }
        handle.setTaskCompleted(success: success)
    }
}

extension AnalysisOutcome {
    var isSuccess: Bool {
        if case .failed = self { false } else { true }
    }
}
