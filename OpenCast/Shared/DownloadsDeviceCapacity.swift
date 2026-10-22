import Foundation

/// The free space the system would make for an important write, the figure
/// Settings › General › iPhone Storage reports. The volume query can take a
/// moment, so it runs off the main actor.
nonisolated enum DownloadsDeviceCapacity {
    /// Nil when the volume can't be read; the caption that shows it hides.
    @concurrent
    static func availableForImportantUsage(at url: URL = .applicationSupportDirectory) async -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
