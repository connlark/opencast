@preconcurrency import BackgroundTasks
import Foundation
import OSLog

struct BGTaskSchedulerAdFreePassScheduler: AdFreePassContinuedTaskScheduling {
    nonisolated private static let logger = Logger(subsystem: "com.connor.opencast", category: "AdFreePassBackgroundRaw")

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) -> Bool {
        let launchHandler: @Sendable (BGTask) -> Void = { task in
            Self.handle(task, onLaunch: onLaunch)
        }
        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: launchHandler
        )
    }

    private nonisolated static func handle(
        _ task: BGTask,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) {
        logger.log(
            "raw continued processing launch handler invoked identifier=\(task.identifier, privacy: .public) taskType=\(String(describing: type(of: task)), privacy: .public)"
        )
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        Task { @MainActor in
            let handle = BGContinuedProcessingTaskHandleAdapter(task: continuedTask)
            onLaunch(handle)
        }
    }

    var supportsGPUResources: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    func submit(identifier: String, title: String, subtitle: String, requiresGPU: Bool) throws {
        try submit(identifier: identifier, title: title, subtitle: subtitle, requiresGPU: requiresGPU, strategy: .fail)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    func submit(
        identifier: String,
        title: String,
        subtitle: String,
        requiresGPU: Bool,
        strategy: BGContinuedProcessingTaskRequest.SubmissionStrategy
    ) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = strategy
        // Double guard: an unsupported-resources request is
        // rejected at submission, so never ask for GPU the platform denies.
        if requiresGPU && supportsGPUResources {
            request.requiredResources = .gpu
        }
        try BGTaskScheduler.shared.submit(request)
    }
}

private final class BGContinuedProcessingTaskHandleAdapter: AdFreePassContinuedTaskHandle {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress {
        task.progress
    }

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
