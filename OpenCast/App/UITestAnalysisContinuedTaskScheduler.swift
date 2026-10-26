import Foundation
import OpenCastAnalysisProviders

/// UI tests: the Chapters & Summary session's card without the system.
/// `armed` launches a card as soon as it is submitted, so a run reports
/// that it finished under the card; `foreground-only` refuses the card, as
/// a simulator does. Chosen with `--opencast-ui-test-chapters-session=`.
final class UITestAnalysisContinuedTaskScheduler: AnalysisContinuedTaskScheduling {
    enum Mode: String {
        case armed
        case foregroundOnly = "foreground-only"
    }

    private let mode: Mode
    private var launchHandler: (@MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void)?

    init(mode: Mode) {
        self.mode = mode
    }

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool {
        guard mode == .armed else {
            return false
        }
        launchHandler = onLaunch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        guard let launchHandler else {
            return
        }
        Task { @MainActor in
            launchHandler(UITestAnalysisContinuedTaskHandle())
        }
    }

    func cancel(identifier: String) {}
}

private final class UITestAnalysisContinuedTaskHandle: AnalysisContinuedTaskHandle {
    let progress = Progress(totalUnitCount: 0)

    func updateTitle(_ title: String, subtitle: String) {}

    func setTaskCompleted(success: Bool) {}

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {}
}
