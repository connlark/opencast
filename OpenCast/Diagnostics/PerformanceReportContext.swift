import Foundation

nonisolated struct PerformanceReportContext: Codable, Sendable {
    let state: PerformanceState
    let durationSeconds: Double
    let measurements: [PerformanceMeasurement]
}
