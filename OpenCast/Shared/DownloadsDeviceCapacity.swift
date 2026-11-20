import Foundation

/// The figure Settings › General › iPhone Storage reports. The volume query can take a
/// moment, so it runs off the main actor.
nonisolated enum DownloadsDeviceCapacity {
    /// Nil when the volume can't be read.
    @concurrent
    static func availableForImportantUsage(at url: URL = .applicationSupportDirectory) async -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
