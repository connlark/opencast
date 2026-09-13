import Foundation

nonisolated struct PerformanceMeasurement: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable {
        case launchSeconds, resumeSeconds, hangSeconds, animationHitchSeconds, animationSeconds
        case cpuSeconds, gpuSeconds, peakMemoryBytes, diskWriteBytes, foregroundSeconds, backgroundAudioSeconds
    }
    let name: Name
    let value: Double
    var upperBound: Double?
    var count: Int?
}
