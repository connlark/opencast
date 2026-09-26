import Foundation

/// The Release-capable remote-job diagnostic trail: one JSON object per line
/// in `<Documents>/remote-job-diagnostics.jsonl`, bounded by
/// `RotatingDiagnosticFile`. It accepts only the typed event, re-checks the
/// encoded keys against the allow-list before anything touches disk, and
/// drops a record it cannot encode rather than asserting. It is separate
/// from the DEBUG-only pass run log, which records titles.
///
/// Retrieve it from a device with
/// `xcrun devicectl device copy from … --source Documents/remote-job-diagnostics.jsonl`.
nonisolated final class RemoteJobDiagnosticLog: RemoteJobDiagnosticSink {
    static let fileName = "remote-job-diagnostics.jsonl"

    static let shared = RemoteJobDiagnosticLog(
        fileURL: URL.documentsDirectory.appending(path: RemoteJobDiagnosticLog.fileName)
    )

    private let file: RotatingDiagnosticFile

    init(fileURL: URL, maximumByteCount: Int = RotatingDiagnosticFile.defaultMaximumByteCount) {
        file = RotatingDiagnosticFile(fileURL: fileURL, maximumByteCount: maximumByteCount)
    }

    var fileURL: URL {
        file.fileURL
    }

    var previousFileURL: URL {
        file.previousFileURL
    }

    func record(_ event: RemoteJobDiagnosticEvent) {
        guard let line = Self.encodedLine(for: event) else {
            return
        }
        file.append(line)
    }

    /// Waits for queued records to land on disk.
    func flush() {
        file.flush()
    }

    /// The bytes one event contributes to the file, or nil when the event
    /// cannot be encoded or its encoded keys fall outside the allow-list.
    static func encodedLine(for event: RemoteJobDiagnosticEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(event), isWithinAllowList(encoded) else {
            return nil
        }
        return encoded + Data("\n".utf8)
    }

    /// True when the encoded object carries only the event's allowed
    /// top-level keys and its `error` object carries only the classifier's
    /// allowed keys. Anything else is refused before it reaches disk.
    static func isWithinAllowList(_ encoded: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              Set(object.keys).isSubset(of: RemoteJobDiagnosticEvent.allowedFieldNames)
        else {
            return false
        }
        guard let error = object["error"] else {
            return true
        }
        guard let errorObject = error as? [String: Any] else {
            return false
        }
        return Set(errorObject.keys).isSubset(of: RemoteJobDiagnosticError.allowedFieldNames)
    }

    /// Decodes a trail written by this log, for tests and device readbacks.
    static func decodeLines(_ data: Data) -> [RemoteJobDiagnosticEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(RemoteJobDiagnosticEvent.self, from: Data($0)) }
    }
}
