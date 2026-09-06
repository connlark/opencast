import Foundation

/// Immutable ownership token. Published sources keep their files alive; dropping
/// the last reference removes the entire job on every exit path.
final class FeedWorkspace: Sendable {
    let directory: URL

    private static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCastFeedJobs", isDirectory: true)
        // Initialization is serialized by Swift. No current-process jobs exist
        // yet; previous-process temporary jobs can never be replayed.
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    static func cleanAbandonedJobs() { _ = root }

    init() throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
