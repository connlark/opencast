import Foundation

/// A running continued-processing task: the system card a run holds so it
/// can finish after the app leaves the foreground.
@MainActor
public protocol AnalysisContinuedTaskHandle: AnyObject {
    var progress: Progress { get }

    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
}

/// Registers, submits and cancels continued-processing task requests.
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
    /// Whether the session named `identifier` may submit its card now. A
    /// refused session runs its work in the foreground only.
    func mayArm(identifier: String) -> Bool
}
