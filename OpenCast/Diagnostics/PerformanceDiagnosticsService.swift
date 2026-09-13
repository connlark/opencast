import Foundation

final class PerformanceDiagnosticsService {
    private let collector = PerformanceReportCollector()
    private var startupTask: Task<Void, Never>?

    func start() {
        guard startupTask == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let builder = PerformanceReportBuilder(
            appVersion: "\(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))",
            toolchainVersion: "Xcode \(info["DTXcodeBuild"] as? String ?? "unknown"); Swift 6.4"
        )
        let collector = collector
        startupTask = Task { await collector.start(builder: builder) }
    }

    deinit {
        startupTask?.cancel()
        let collector = collector
        Task { await collector.stop() }
    }
}
