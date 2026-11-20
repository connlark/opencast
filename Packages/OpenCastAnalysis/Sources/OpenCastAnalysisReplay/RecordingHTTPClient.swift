import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// Records structured fields only, never a URL, a header or a provider message. The spend hook
/// runs inside the exchange's deadline: `reserve` time comes out of the provider call, and a hook
/// still running at the deadline fails the exchange as a timeout.
final class RecordingHTTPClient: AnalysisHTTPClient {
    typealias Kind = AnalysisExchangeRecord.Kind

    private let inner: any AnalysisHTTPClient
    private let directory: URL
    private let provider: AnalysisProvider
    private let model: AnalysisModelEntry
    private let key: AnalysisProviderKey
    private let hook: SpendHook?
    private let maxGenerateSends: Int
    private let context: [String: String]
    private let state = Mutex<(sequence: Int, generateSends: Int, refusal: String?)>((0, 0, nil))

    /// Lets `settle`, `release` or `ambiguous` run for a call that answered at its deadline.
    static let bookkeepingFloorSeconds = 2.0

    init(
        inner: any AnalysisHTTPClient,
        directory: URL,
        provider: AnalysisProvider,
        model: AnalysisModelEntry,
        key: AnalysisProviderKey,
        hook: SpendHook?,
        maxGenerateSends: Int,
        context: [String: String]
    ) throws {
        self.inner = inner
        self.directory = directory.appending(path: "exchanges")
        self.provider = provider
        self.model = model
        self.key = key
        self.hook = hook
        self.maxGenerateSends = maxGenerateSends
        self.context = context
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    var refusal: String? { state.withLock { $0.refusal } }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let deadline = ContinuousClock.now + .seconds(AnalysisProviderLimits.waitSeconds(timeoutSeconds))
        func remaining() -> Double {
            let left = ContinuousClock.now.duration(to: deadline)
            return Double(left.components.seconds) + Double(left.components.attoseconds) * 1e-18
        }
        let kind = AnalysisExchangeRecord.kind(of: request)
        let (sequence, refused): (Int, String?) = state.withLock { state in
            state.sequence += 1
            if state.refusal == nil, kind == .generate {
                state.generateSends += 1
                if state.generateSends > maxGenerateSends { state.refusal = "send cap \(maxGenerateSends) reached" }
            }
            return (state.sequence, kind == .generate ? state.refusal : nil)
        }
        let number = String(sequence)
        let name = String(repeating: "0", count: max(0, 3 - number.count)) + number + "-" + kind.rawValue
        let requestRecorded = write(name + ".request.json", AnalysisExchangeRecord.request(request, key: key))
        if let refused {
            write(name + ".meta.json", .object(["refused": .string(refused)]))
            throw .network
        }
        var meta: [JSONMember] = [
            JSONMember("kind", .string(kind.rawValue)),
            JSONMember("timeout_s", .double(Self.milliseconds(timeoutSeconds))),
            JSONMember("request_recorded", .bool(requestRecorded)),
        ]
        var callContext = context
        callContext["kind"] = kind.rawValue
        callContext["sequence"] = String(sequence)
        let contextText = JSONWriter.string(.object(callContext.sorted { $0.key < $1.key }.map { JSONMember($0.key, .string($0.value)) }))
        var reservation: String?
        if let hook {
            // Half the body's bytes: above any provider's token count for JSON
            // text, so the reservation bounds the call.
            let inputBound = kind == .generate ? ((request.body?.count ?? 0) + 1) / 2 : 0
            let maxOutput = kind == .generate ? model.maxOutputTokens : 1
            let reply = await hook.run([
                "reserve", "--model", model.modelID, "--input-tokens", String(inputBound),
                "--max-output", String(maxOutput), "--context", contextText,
            ], timeoutSeconds: remaining())
            switch reply.ending {
            case .timedOut:
                // The ledger may hold a reservation this tool never learned;
                // stop sending so it can be reconciled by hand.
                state.withLock { $0.refusal = $0.refusal ?? "spend hook reserve timed out" }
                meta.append(JSONMember("refused", .string("spend hook reserve timed out")))
                write(name + ".meta.json", .object(meta))
                throw .timeout
            case .cancelled:
                meta.append(JSONMember("refused", .string("cancelled during spend hook reserve")))
                write(name + ".meta.json", .object(meta))
                throw .network
            case .exited, .failedToStart:
                break
            }
            guard reply.status == 0, let id = reply.output?["reservation"]?.stringValue else {
                let reason = "spend hook refused (exit \(reply.status))"
                state.withLock { $0.refusal = $0.refusal ?? reason }
                meta.append(JSONMember("refused", .string(reason)))
                write(name + ".meta.json", .object(meta))
                throw .network
            }
            reservation = id
            meta.append(JSONMember("reservation", .string(Self.isReservationID(id) ? id : "invalid")))
            meta.append(JSONMember("input_bound", .integer(inputBound)))
            meta.append(JSONMember("max_output", .integer(maxOutput)))
        }
        let started = ContinuousClock.now
        let result: Result<AnalysisHTTPResponse, AnalysisHTTPFailure>
        let left = remaining()
        let sent = left > 0
        if !sent {
            result = .failure(.timeout)
        } else {
            do {
                result = .success(try await inner.send(request, timeoutSeconds: left, maximumBodyBytes: maximumBodyBytes))
            } catch {
                result = .failure(error)
            }
        }
        meta.append(JSONMember("send_timeout_s", .double(Self.milliseconds(left))))
        let elapsed = started.duration(to: .now)
        meta.append(JSONMember("seconds", .double(Self.milliseconds(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18))))
        switch result {
        case .success(let response):
            let raw = String(decoding: response.body, as: UTF8.self)
            // Billed counts come from the raw response, before redaction, so a suppressed
            // recording never stops the ledger settling.
            let usage = kind == .generate && (200..<300).contains(response.status)
                ? AnalysisBilledUsage.billed(provider: provider, body: raw)
                : nil
            let record = AnalysisExchangeRecord.response(response, provider: provider, kind: kind, key: key)
            let recording = key.verifiedRecording(record)
            try? Data((recording.text + "\n").utf8).write(to: directory.appending(path: name + ".response.json"))
            meta.append(JSONMember("response_recorded", .bool(recording.recorded)))
            if let reason = recording.reason { meta.append(JSONMember("response_suppressed", .string(reason))) }
            meta.append(JSONMember("status", .integer(response.status)))
            if let seconds = response.retryAfterSeconds { meta.append(JSONMember("retry_after_s", .integer(seconds))) }
            if let hook, let reservation {
                let definite = [400, 401, 403, 404, 413, 422, 429].contains(response.status)
                let arguments: [String] = if kind == .generate, (200..<300).contains(response.status), let usage {
                    ["settle", "--reservation", reservation, "--provider", provider.rawValue,
                     "--usage", Self.usageJSON(usage),
                     "--summary-dir", directory.deletingLastPathComponent().path(percentEncoded: false),
                     "--model", model.modelID, "--context", contextText]
                } else if kind == .generate, (200..<300).contains(response.status) {
                    ["ambiguous", "--reservation", reservation, "--error", "no usage in response"]
                } else if kind != .generate || definite {
                    ["release", "--reservation", reservation, "--error", "status \(response.status)"]
                } else {
                    ["ambiguous", "--reservation", reservation, "--error", "status \(response.status)"]
                }
                let reply = await hook.run(arguments, timeoutSeconds: max(remaining(), Self.bookkeepingFloorSeconds))
                meta.append(JSONMember("ledger", .string(arguments[0])))
                meta.append(JSONMember("ledger_exit", .integer(Int(reply.status))))
                if let cost = reply.output?["cost_usd"], case .number = cost { meta.append(JSONMember("cost_usd", cost)) }
                if reply.status != 0 {
                    state.withLock { $0.refusal = $0.refusal ?? "spend hook \(arguments[0]) exit \(reply.status)" }
                }
            }
            write(name + ".meta.json", .object(meta))
            return response
        case .failure(let failure):
            meta.append(JSONMember("failure", .string(AnalysisExchangeRecord.failureName(failure))))
            if let hook, let reservation {
                // Never sent, or not a generate call: nothing was billed.
                let operation = kind == .generate && sent ? "ambiguous" : "release"
                let reply = await hook.run(
                    [operation, "--reservation", reservation, "--error", "\(failure)"],
                    timeoutSeconds: max(remaining(), Self.bookkeepingFloorSeconds)
                )
                meta.append(JSONMember("ledger", .string(operation)))
                meta.append(JSONMember("ledger_exit", .integer(Int(reply.status))))
                if reply.status != 0 {
                    state.withLock { $0.refusal = $0.refusal ?? "spend hook \(operation) exit \(reply.status)" }
                }
            }
            write(name + ".meta.json", .object(meta))
            throw failure
        }
    }

    /// Returns false when a placeholder replaced the artifact.
    @discardableResult
    private func write(_ name: String, _ value: JSONValue) -> Bool {
        let recording = key.verifiedRecording(value)
        try? Data((recording.text + "\n").utf8).write(to: directory.appending(path: name))
        return recording.recorded
    }

    static func usageJSON(_ usage: AnalysisBilledUsage) -> String {
        JSONWriter.string(.object([
            JSONMember("input", .integer(Int(clamping: usage.input))),
            JSONMember("cached", .integer(Int(clamping: usage.cached))),
            JSONMember("write", .integer(Int(clamping: usage.write))),
            JSONMember("output", .integer(Int(clamping: usage.output))),
            JSONMember("reasoning", .integer(Int(clamping: usage.reasoning))),
        ]))
    }

    /// Full precision carries digit runs that can match four digits of the key and fail the file's
    /// fragment check by chance; to the millisecond, a time under 1,000 s has no run of four.
    static func milliseconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return (seconds * 1000).rounded() / 1000
    }

    static func isReservationID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A }
    }
}

extension RecordingHTTPClient: CustomStringConvertible, CustomReflectable {
    var description: String { "RecordingHTTPClient(\(provider.rawValue))" }
    var customMirror: Mirror { Mirror(self, children: []) }
}

final class FileLogSink: AnalysisLogSink {
    private let handle: Mutex<FileHandle?>

    init(_ url: URL) {
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        handle = Mutex(try? FileHandle(forWritingTo: url))
    }

    func write(_ line: String) {
        handle.withLock { handle in
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
