import CryptoKit
import Foundation
@testable import OpenCastAnalysis

enum TestSupport {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let repositoryRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()

    static func fixture(_ name: String) throws -> JSONValue {
        let url = packageRoot.appending(path: "Tests/OpenCastAnalysisTests/Fixtures/\(name)")
        return try JSONParser.parse(try String(contentsOf: url, encoding: .utf8))
    }

    static func repositoryText(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// Payloads and prepared requests replaced by the size and SHA-256 of
    /// their canonical text, as the goldens store them.
    static func digestPayloads(_ value: JSONValue) -> JSONValue {
        func digest(_ value: JSONValue) -> JSONValue {
            let text = Data(JSONWriter.string(value.sortedKeys()).utf8)
            let hash = SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined()
            return .object(["bytes": .integer(text.count), "sha256": .string(hash)])
        }
        switch value {
        case .array(let values):
            return .array(values.map(digestPayloads))
        case .object(let members):
            return .object(members.map { member in
                switch (member.key, member.value) {
                case ("payload", .object), ("model_request", .object):
                    return JSONMember(member.key, digest(member.value))
                case ("payloads", .object(let payloads)):
                    return JSONMember(member.key, .object(payloads.map { JSONMember($0.key, digest($0.value)) }))
                default:
                    return JSONMember(member.key, digestPayloads(member.value))
                }
            })
        default:
            return value
        }
    }

    /// A replay transport whose replies are scripted per send, for ladder
    /// tests: each request purpose consumes its list in order.
    actor ScriptedTransport: AnalysisProviderTransport {
        private var scripts: [AnalysisProviderRequest.Purpose: [Result<AnalysisProviderReply, AnalysisTransportError>]]
        private(set) var sent: [AnalysisProviderRequest] = []

        init(_ scripts: [AnalysisProviderRequest.Purpose: [Result<AnalysisProviderReply, AnalysisTransportError>]]) {
            self.scripts = scripts
        }

        func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
            sent.append(request)
            guard var script = scripts[request.purpose], !script.isEmpty else { throw .notArchived }
            let next = script.removeFirst()
            scripts[request.purpose] = script
            return try next.get()
        }
    }

    /// A clock that advances only when the pipeline sleeps, recording each
    /// pause.
    final class SteppingClock: AnalysisClock, @unchecked Sendable {
        // Guarded by `lock`; the pipeline may sleep from several windows.
        private let lock = NSLock()
        private var current = 0.0
        private var pauses: [Double] = []

        func now() -> Double { lock.withLock { current } }

        func sleep(seconds: Double) async throws {
            lock.withLock {
                current += seconds
                pauses.append(seconds)
            }
        }

        func advance(_ seconds: Double) { lock.withLock { current += seconds } }

        var recordedPauses: [Double] { lock.withLock { pauses } }
    }

    static func geminiBody(_ answer: String, finish: String = "STOP") -> String {
        JSONWriter.string(.object([
            "candidates": .array([.object([
                "content": .object(["parts": .array([.object(["text": .string(answer)])])]),
                "finishReason": .string(finish),
            ])]),
            "usageMetadata": .object([
                "promptTokenCount": .integer(10), "candidatesTokenCount": .integer(5),
                "thoughtsTokenCount": .integer(2), "totalTokenCount": .integer(17),
            ]),
        ]))
    }
}
