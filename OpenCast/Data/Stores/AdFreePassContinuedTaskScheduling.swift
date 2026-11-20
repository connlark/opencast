import Foundation

@MainActor
protocol AdFreePassContinuedTaskHandle: AnyObject {
    var progress: Progress { get }

    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
}

@MainActor
protocol AdFreePassContinuedTaskScheduling {
    /// iPads report `.gpu` in `BGTaskScheduler.supportedResources`; iPhones and simulators do not.
    var supportsGPUResources: Bool { get }

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) -> Bool
    func submit(identifier: String, title: String, subtitle: String, requiresGPU: Bool) throws
    func cancel(identifier: String)
}
