import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// `reproject`: rewrites exchanges recorded before the recorder kept
/// structured fields only (request with method, URL and body; the response
/// body itself; a meta file) into today's records, through the same
/// ``AnalysisExchangeRecord`` functions and verification the live recorder
/// uses. Prints counts only.
struct Reproject {
    let arguments: Arguments

    /// The meta fields a record keeps: the tool's own bookkeeping, numbers
    /// and closed values.
    static let metaNumbers = ["timeout_s", "send_timeout_s", "seconds", "input_bound", "max_output", "status", "retry_after_s", "ledger_exit"]
    static let metaClosed: [String: Set<String>] = [
        "kind": ["generate", "count", "key_test"],
        "ledger": ["settle", "release", "ambiguous"],
        "failure": ["timeout", "network", "oversized_body", "oversizedBody"],
    ]

    func run() throws -> JSONValue {
        let name = try arguments.required("provider")
        guard let provider = AnalysisProvider(rawValue: name) else {
            throw AnalysisReplay.InputError(description: "unknown provider \(name)")
        }
        let key = try LiveRun(arguments: arguments).key()
        let input = URL(filePath: try arguments.required("exchanges"), directoryHint: .isDirectory)
        let output = URL(filePath: try arguments.required("out"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: input.path(percentEncoded: false))
        let stems = Set(names.compactMap { $0.hasSuffix(".meta.json") ? String($0.dropLast(".meta.json".count)) : nil })
        var counts: [String: Int] = [:]
        for stem in stems.sorted() {
            let meta = try readJSON(input.appending(path: stem + ".meta.json").path(percentEncoded: false))
            let requestValue = try? readJSON(input.appending(path: stem + ".request.json").path(percentEncoded: false))
            var request = AnalysisHTTPRequest(
                method: requestValue?["method"]?.stringValue ?? "POST",
                url: URL(string: requestValue?["url"]?.stringValue ?? "https://invalid.example/") ?? URL(filePath: "/"),
                headers: [],
                body: nil
            )
            if let body = requestValue?["body"] { request.body = Data(JSONWriter.string(body).utf8) }
            let kind = AnalysisExchangeRecord.Kind(rawValue: meta["kind"]?.stringValue ?? "") ?? AnalysisExchangeRecord.kind(of: request)
            try write(AnalysisExchangeRecord.request(request, key: key), to: output.appending(path: stem + ".request.json"), key: key, counts: &counts)
            let responsePath = input.appending(path: stem + ".response.json")
            if let status = Self.count(meta["status"]), let body = try? Data(contentsOf: responsePath) {
                let retryAfter = Self.count(meta["retry_after_s"]).map(String.init)
                let response = AnalysisHTTPResponse(status: Int(status), retryAfter: retryAfter, body: body.trimmingTrailingNewline)
                let record = AnalysisExchangeRecord.response(response, provider: provider, kind: kind, key: key)
                try write(record, to: output.appending(path: stem + ".response.json"), key: key, counts: &counts)
            }
            try write(Self.meta(meta), to: output.appending(path: stem + ".meta.json"), key: key, counts: &counts)
            counts["exchanges", default: 0] += 1
        }
        return .object(counts.sorted { $0.key < $1.key }.map { JSONMember($0.key, .integer($0.value)) })
    }

    static func count(_ value: JSONValue?) -> UInt64? {
        guard case .number(.unsigned(let count)) = value else { return nil }
        return count
    }

    /// The old meta reduced to the fields a record keeps.
    static func meta(_ old: JSONValue) -> JSONValue {
        guard case .object(let members) = old else { return .object([]) }
        var kept: [JSONMember] = []
        for member in members {
            if ["timeout_s", "send_timeout_s", "seconds"].contains(member.key), case .number(let number) = member.value {
                kept.append(JSONMember(member.key, .double(RecordingHTTPClient.milliseconds(number.doubleValue))))
            } else if metaNumbers.contains(member.key), case .number = member.value {
                kept.append(member)
            } else if let allowed = metaClosed[member.key], let value = member.value.stringValue, allowed.contains(value) {
                kept.append(JSONMember(member.key, .string(value == "oversizedBody" ? "oversized_body" : value)))
            } else if member.key == "cost_usd", case .number = member.value {
                kept.append(member)
            } else if ["request_recorded", "response_recorded"].contains(member.key), case .bool = member.value {
                kept.append(member)
            } else if member.key == "reservation", let id = member.value.stringValue {
                kept.append(JSONMember(member.key, .string(RecordingHTTPClient.isReservationID(id) ? id : "invalid")))
            }
        }
        return .object(kept)
    }

    func write(_ value: JSONValue, to url: URL, key: AnalysisProviderKey, counts: inout [String: Int]) throws {
        let recording = key.verifiedRecording(value)
        try Data((recording.text + "\n").utf8).write(to: url)
        counts[recording.recorded ? "files_recorded" : "files_suppressed", default: 0] += 1
    }
}

extension Data {
    /// Without the newline the recorder ended every file with.
    var trimmingTrailingNewline: Data {
        last == 0x0A ? dropLast() : self
    }
}
