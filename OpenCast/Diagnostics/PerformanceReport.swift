import Foundation

nonisolated struct PerformanceReport: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metrics, crash, hang, cpuException, diskWriteException, launch, memoryException
    }

    var formatVersion = 1
    let id: UUID
    let receivedAt: Date
    let appVersion: String
    let toolchainVersion: String
    let kind: Kind
    let timeRange: DateInterval
    var states: [PerformanceState] = []
    var measurements: [PerformanceMeasurement] = []
    var frames: [PerformanceStackFrame] = []
    var contexts: [PerformanceReportContext] = []
    var sourceAppVersion: String?
    var includesMultipleAppVersions = false

    func validate() throws {
        guard formatVersion == 1, states.count <= 100, measurements.count <= 10_000, frames.count <= 4096, contexts.count <= 100,
              appVersion.count <= 128, toolchainVersion.count <= 128, (sourceAppVersion?.count ?? 0) <= 128,
              timeRange.duration.isFinite, timeRange.duration >= 0,
              timeRange.start.timeIntervalSince1970.isFinite,
              receivedAt.timeIntervalSince1970.isFinite,
              states.allSatisfy({ $0.domain.labels.contains($0.label) }),
              contexts.allSatisfy({ context in
                  context.state.domain.labels.contains(context.state.label)
                      && context.durationSeconds.isFinite && context.durationSeconds >= 0
                      && context.measurements.count <= 10_000
                      && context.measurements.allSatisfy { $0.value.isFinite && $0.value >= 0 && ($0.upperBound?.isFinite ?? true) && ($0.count ?? 0) >= 0 }
              }),
              measurements.allSatisfy({ $0.value.isFinite && $0.value >= 0 && ($0.upperBound?.isFinite ?? true) && ($0.count ?? 0) >= 0 })
        else { throw PerformanceReportError.invalidReport }
    }
}
