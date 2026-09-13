import Foundation

nonisolated enum PerformanceReportError: Error, LocalizedError {
    case invalidReport, oversized, unavailable, empty
    var errorDescription: String? {
        switch self {
        case .invalidReport: "A performance report could not be read."
        case .oversized: "The performance report exceeds the local storage limit."
        case .unavailable: "OpenCast could not access its local performance reports. Try again."
        case .empty: "No performance reports are available yet."
        }
    }
}
