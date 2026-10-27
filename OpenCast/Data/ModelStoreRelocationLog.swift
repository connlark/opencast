import Foundation
import os

/// One line per store per launch, to the unified log and to a capped file in
/// the app data container: a Wi-Fi-paired device exposes its container to
/// `devicectl device copy from` but not its unified log.
nonisolated struct ModelStoreRelocationLog: Sendable {
    let fileURL: URL
    let maximumByteCount: Int
    private let logger: Logger

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "Diagnostics/store-relocation.log"),
        maximumByteCount: Int = 256 * 1024,
        logger: Logger = Logger(subsystem: "com.connor.opencast", category: "StoreRelocation")
    ) {
        self.fileURL = fileURL
        self.maximumByteCount = maximumByteCount
        self.logger = logger
    }

    /// Never throws: a file that cannot be written is reported through the
    /// logger and the launch goes on.
    func record(_ results: [ModelStoreRelocationResult], at date: Date = .now) {
        let lines = results.map(Self.line(for:))
        for (result, line) in zip(results, lines) {
            if case .deferred = result.outcome {
                logger.error("\(line, privacy: .public)")
            } else {
                logger.notice("\(line, privacy: .public)")
            }
        }
        let stamp = date.formatted(.iso8601)
        do {
            try append(Data(lines.map { "\(stamp) \($0)\n" }.joined().utf8))
        } catch {
            logger.error("store relocation log not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func line(for result: ModelStoreRelocationResult) -> String {
        [
            "\(result.configurationName) \(description(of: result.outcome))",
            "uuid \(result.storeUUID ?? "unread")",
            "wal \(result.walSize.map { "\($0) bytes" } ?? "unprobed")",
            "companions \(result.companions.isEmpty ? "none" : result.companions.joined(separator: ", "))",
            "notes \(result.notes.isEmpty ? "none" : result.notes.joined(separator: " | "))",
            "opens \(result.resolvedURL.path(percentEncoded: false))"
        ]
        .joined(separator: "; ")
        .replacing("\n", with: " ")
        .replacing("\r", with: " ")
    }

    private static func description(of outcome: ModelStoreRelocationResult.Outcome) -> String {
        switch outcome {
        case .moved:
            "moved"
        case .inPlace:
            "in place"
        case .ambiguous:
            "ambiguous"
        case .deferred(.invalid(let detail)):
            "deferred, invalid: \(detail)"
        case .deferred(.inaccessible(let detail)):
            "deferred, inaccessible: \(detail)"
        case .deferred(.unsupported(let detail)):
            "deferred, unsupported: \(detail)"
        case .deferred(.interrupted(let step, let detail)):
            "deferred, interrupted at \(step.rawValue): \(detail)"
        }
    }

    /// A file that the new lines would take past the cap keeps only them.
    private func append(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        if try handle.seekToEnd() + UInt64(data.count) > UInt64(maximumByteCount) {
            try handle.truncate(atOffset: 0)
        }
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
