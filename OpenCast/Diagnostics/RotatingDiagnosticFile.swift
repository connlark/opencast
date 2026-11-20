import Foundation

/// Every file operation and every access to `currentByteCount` happens on `queue`, which
/// makes it Sendable. Failures are dropped, never asserted: a diagnostic sink must not
/// crash a Release device.
nonisolated final class RotatingDiagnosticFile: @unchecked Sendable {
    static let defaultMaximumByteCount = 256 * 1024

    let fileURL: URL
    let maximumByteCount: Int

    private let queue: DispatchQueue
    /// Read from disk once, then tracked here so appends do not stat the file.
    private var currentByteCount: Int?

    init(fileURL: URL, maximumByteCount: Int = RotatingDiagnosticFile.defaultMaximumByteCount) {
        self.fileURL = fileURL
        self.maximumByteCount = maximumByteCount
        queue = DispatchQueue(label: "com.connor.opencast.rotating-diagnostic-file", qos: .utility)
    }

    var previousFileURL: URL {
        fileURL.appendingPathExtension("previous")
    }

    func append(_ data: Data) {
        queue.async { [self] in
            write(data)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = currentByteCount ?? storedByteCount(fileManager: fileManager)
            if existing + data.count > maximumByteCount, existing > 0 {
                rotate(fileManager: fileManager)
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
                currentByteCount = 0
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentByteCount = (currentByteCount ?? existing) + data.count
        } catch {
            currentByteCount = nil
        }
    }

    private func storedByteCount(fileManager: FileManager) -> Int {
        // FileManager attributes, not URL.resourceValues: NSURL caches
        // resource values per instance, so a reused URL would report a stale
        // size and rotation would never trigger.
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let count = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        currentByteCount = count
        return count
    }

    private func rotate(fileManager: FileManager) {
        try? fileManager.removeItem(at: previousFileURL)
        try? fileManager.moveItem(at: fileURL, to: previousFileURL)
        currentByteCount = 0
    }
}
