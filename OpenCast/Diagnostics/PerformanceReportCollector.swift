import Foundation
import MetricKit

actor PerformanceReportCollector {
    private var tasks: [Task<Void, Never>] = []
    private var hasStopped = false

    func start(builder: PerformanceReportBuilder, store: PerformanceReportStore = .shared) {
        guard tasks.isEmpty, !hasStopped, !Task.isCancelled else { return }
        let domains = Set(PerformanceState.Domain.allCases.map { StateReportingDomain(rawValue: $0.identifier) })
        let manager = MetricManager(enabledStateReportingDomains: domains)
        tasks = [
            Task {
                for await report in manager.metricReports {
                    guard !Task.isCancelled else { return }
                    await store.receive(builder.metrics(report))
                }
            },
            Task {
                for await report in manager.diagnosticReports {
                    guard !Task.isCancelled else { return }
                    await store.receive(builder.diagnostic(report))
                }
            }
        ]
    }

    func stop() {
        hasStopped = true
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit { tasks.forEach { $0.cancel() } }
}
