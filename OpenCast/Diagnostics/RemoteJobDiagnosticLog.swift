import Foundation

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

    func flush() {
        file.flush()
    }

    /// Nil when the event cannot be encoded or its keys fall outside the allow-list.
    static func encodedLine(for event: RemoteJobDiagnosticEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(event), isWithinAllowList(encoded) else {
            return nil
        }
        return encoded + Data("\n".utf8)
    }

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

    static func decodeLines(_ data: Data) -> [RemoteJobDiagnosticEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(RemoteJobDiagnosticEvent.self, from: Data($0)) }
    }
}
