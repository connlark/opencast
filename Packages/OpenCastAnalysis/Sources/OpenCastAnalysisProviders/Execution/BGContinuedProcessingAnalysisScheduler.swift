#if os(iOS)
@preconcurrency import BackgroundTasks
import Foundation

/// ``AnalysisContinuedTaskScheduling`` on `BGTaskScheduler`: continued
/// processing requests with the `.fail` strategy (a second concurrent card is
/// refused, not queued) and no GPU.
public struct BGContinuedProcessingAnalysisScheduler: AnalysisContinuedTaskScheduling {
    public init() {}

    public func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: Self.launchHandler(onLaunch)
        )
    }

    /// Built outside the main actor: the system calls it on a background
    /// queue.
    private nonisolated static func launchHandler(
        _ onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> @Sendable (BGTask) -> Void {
        { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                onLaunch(BGContinuedProcessingAnalysisTaskHandle(task: continued))
            }
        }
    }

    public func submit(identifier: String, title: String, subtitle: String) async throws {
        try await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
    }

    /// Off the main thread, as the scheduler asks of submissions.
    @concurrent
    private nonisolated static func submitRequest(identifier: String, title: String, subtitle: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    public func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

private final class BGContinuedProcessingAnalysisTaskHandle: AnalysisContinuedTaskHandle {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress { task.progress }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }
}
#endif
