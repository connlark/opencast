import Foundation
import os

/// Sparse playback transitions, retained locally across launches in release
/// builds so source selection and skip landings survive a later bug report.
/// Use one active writer per log path.
actor PlaybackEventLog {
    static let shared = PlaybackEventLog()
    private let fileURL: URL
    private let maximumByteCount: Int
    private var fileHandle: FileHandle?
    private var currentByteCount = 0
    private let logger = Logger(subsystem: "com.connor.opencast", category: "PlaybackEventLog")

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "PlaybackDiagnostics/playback-events.log"),
        maximumByteCount: Int = 128 * 1024
    ) {
        self.fileURL = fileURL
        self.maximumByteCount = max(1, maximumByteCount)
    }

    isolated deinit {
        try? fileHandle?.close()
    }

    func record(_ message: String) {
        let line = message.replacing("\n", with: " ").replacing("\r", with: " ") + "\n"
        let data = Data(line.utf8.prefix(maximumByteCount))
        do {
            var handle = try openFileIfNeeded()
            if currentByteCount > maximumByteCount - data.count {
                try handle.close()
                fileHandle = nil
                let previousURL = fileURL.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: previousURL)
                try FileManager.default.moveItem(at: fileURL, to: previousURL)
                handle = try openFileIfNeeded()
            }
            try handle.write(contentsOf: data)
            currentByteCount += data.count
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            logger.error("Could not persist playback event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openFileIfNeeded() throws -> FileHandle {
        if let fileHandle { return fileHandle }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            try Data().write(to: fileURL, options: .atomic)
            handle = try FileHandle(forWritingTo: fileURL)
        }
        currentByteCount = Int(clamping: try handle.seekToEnd())
        fileHandle = handle
        return handle
    }
}
