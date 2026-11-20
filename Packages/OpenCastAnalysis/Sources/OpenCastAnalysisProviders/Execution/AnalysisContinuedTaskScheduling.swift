import Foundation

@MainActor
public protocol AnalysisContinuedTaskHandle: AnyObject {
    var progress: Progress { get }

    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
}

@MainActor
public protocol AnalysisContinuedTaskScheduling {
    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool
    func submit(identifier: String, title: String, subtitle: String) async throws
    func cancel(identifier: String)
}

/// The app's one-card rule: at most one continued-processing card at a time.
@MainActor
public protocol AnalysisContinuedTaskArbiter: AnyObject {
    func mayArm(identifier: String) -> Bool
}
