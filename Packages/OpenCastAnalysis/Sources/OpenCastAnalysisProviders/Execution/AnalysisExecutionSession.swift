import Foundation
import OpenCastAnalysis

/// How a run under an ``AnalysisExecutionSession`` ended.
public enum AnalysisExecutionResult: Sendable, Hashable {
    /// The run finished. `background` tells whether a continued-processing
    /// card held it.
    case finished(AnalysisOutcome, background: Bool)
    /// The system (or the listener, from the card) ended the task and the
    /// run was cancelled; resume it from its run record.
    case expired
}

/// Runs one analysis at a time under its own continued-processing task, so
/// a run started in the foreground can finish after the app backgrounds.
/// The card's progress moves on every tick, at most a minute apart, so the
/// system never sees a stalled task while a long provider call is in
/// flight. When the app's arbiter refuses the card, or the system refuses
/// the request, the work runs in the foreground only.
@MainActor
public final class AnalysisExecutionSession {
    public enum State: Sendable, Hashable {
        case idle
        /// The request is submitted and the system has not launched it yet.
        case submitted
        /// The card is up and holds the run.
        case running
        /// No card: refused by the arbiter, the scheduler or the system.
        case foregroundOnly
    }

    /// The longest pause between progress updates.
    public nonisolated static let maxTickInterval: Duration = .seconds(60)
    /// The fewest progress units a run's card has; longer runs at shorter
    /// ticks get more, so every tick can move the card.
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

    /// - Parameters:
    ///   - identifier: The permitted continued-processing identifier.
    ///   - title: The card's title.
    ///   - tickInterval: The pause between progress updates, capped at
    ///     ``maxTickInterval``.
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

    /// Whether this session holds or has requested the card; the arbiter
    /// reads it to refuse other sessions.
    public var isArmed: Bool { state == .submitted || state == .running }

    /// Whether a launched card protects work running on this device.
    public var isProtectingBackgroundExecution: Bool { state == .running && handle != nil }

    /// Runs `work` (one analysis run) under the card. `expectedSeconds` is
    /// the run's budget, which paces the progress creep. Cancelling the
    /// calling task cancels the work. A session runs one run at a time; a
    /// second concurrent call runs its work in the foreground only.
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

    /// Moves the card forward: linearly over the expected run time up to the
    /// creep ceiling, and by at least one unit every tick until one short of
    /// the total.
    func tick() {
        guard let handle, state == .running else { return }
        units = scale.units(after: max(clock.now() - startedAt, 0), previous: units)
        handle.progress.completedUnitCount = units
    }

    /// A run's progress units. The total holds at least twenty units per
    /// tick of the expected run, so the linear creep moves the card on every
    /// tick (start 1 %, ceiling 90 % at the expected time) and the one-unit
    /// floor after the ceiling lasts at least twice the expected run again.
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
