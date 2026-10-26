import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// `live` and `key-test`: one real run (or key test) against a provider
/// with a key read from a file, recorded under `--out`.
struct LiveRun {
    let arguments: Arguments

    var provider: AnalysisProvider {
        get throws(AnalysisReplay.InputError) {
            let name = try arguments.required("provider")
            guard let provider = AnalysisProvider(rawValue: name) else {
                throw AnalysisReplay.InputError(description: "unknown provider \(name)")
            }
            return provider
        }
    }

    /// The model entry: the baked bundle's entry for the provider and model
    /// when it has one, else the service entry with the provider, model and
    /// thinking level replaced.
    func entry(feature: AnalysisFeature) throws(AnalysisReplay.InputError) -> AnalysisModelEntry {
        let provider = try provider
        let modelID = try arguments.required("model")
        let bundle = AnalysisPolicyBundle.baked
        let listed = feature == .adDetection
            ? bundle.features.adDetection.qualifiedModels
            : bundle.features.chaptersSummary.allowedModels
        var entry = listed.first { $0.provider == provider && $0.modelID == modelID }
            ?? (feature == .adDetection ? AnalysisModelEntry.serviceAdDetection : AnalysisModelEntry.serviceChaptersSummary)
        entry.provider = provider
        if entry.modelID != modelID {
            entry.modelID = modelID
            entry.label = modelID
        }
        if let thinking = arguments.options["thinking"] { entry.thinking = thinking }
        return entry
    }

    func key() throws -> AnalysisProviderKey {
        let path = try arguments.required("key-file")
        guard let key = AnalysisProviderKey(try String(contentsOfFile: path, encoding: .utf8)) else {
            throw AnalysisReplay.InputError(description: "empty key file")
        }
        return key
    }

    struct Context {
        var out: URL
        var key: AnalysisProviderKey
        var client: RecordingHTTPClient
        var transport: any AnalysisKeyedTransport
        var sends: AnalysisProviderSendLog
    }

    func context(entry: AnalysisModelEntry, feature: String) throws -> Context {
        let out = URL(filePath: try arguments.required("out"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let key = try key()
        let provider = try provider
        guard let endpoint = AnalysisPolicyBundle.baked.providers[provider] else {
            throw AnalysisReplay.InputError(description: "no endpoint for \(provider.rawValue)")
        }
        let hook = arguments.options["spend-hook"].map { SpendHook(executable: URL(filePath: $0)) }
        let client = try RecordingHTTPClient(
            inner: URLSessionAnalysisHTTPClient(),
            directory: out,
            provider: provider,
            model: entry,
            key: key,
            hook: hook,
            maxGenerateSends: Int(arguments.options["max-sends"] ?? "") ?? 16,
            context: [
                "provider": provider.rawValue, "feature": feature,
                "fixture": arguments.options["fixture"].map { URL(filePath: $0).lastPathComponent } ?? "",
                "out": out.lastPathComponent,
            ]
        )
        let sends = AnalysisProviderSendLog()
        let logger = RedactingLogger(subsystem: nil, sink: FileLogSink(out.appending(path: "transport.log")))
        let transport: any AnalysisKeyedTransport = provider == .google
            ? try GeminiAnalysisTransport(endpoint: endpoint, key: key, client: client, observer: sends, logger: logger)
            : try OpenAIAnalysisTransport(endpoint: endpoint, key: key, client: client, observer: sends, logger: logger)
        return Context(out: out, key: key, client: client, transport: transport, sends: sends)
    }

    func keyTest() async throws -> JSONValue {
        let entry = try entry(feature: .adDetection)
        let context = try context(entry: entry, feature: "key_test")
        let result = await context.transport.testKey(model: entry)
        let value: JSONValue = switch result {
        case .accepted: .object(["key_test": .string("accepted")])
        case .failed(let failure): .object(["key_test": .string("failed"), "listener_failure": .string(failure.rawValue)])
        }
        return try Self.write(value, to: context.out.appending(path: "outcome.json"), key: context.key)
    }

    func live() async throws -> JSONValue {
        let featureName = try arguments.required("feature")
        let fixturePath = try arguments.required("fixture")
        let fixture = try readJSON(fixturePath)
        let feature: AnalysisFeature = featureName == "ads" ? .adDetection : .chaptersSummary
        let entry = try entry(feature: feature)
        let context = try context(entry: entry, feature: feature.rawValue)
        try Self.write(fixture, to: context.out.appending(path: "request.json"), key: context.key)
        let runner = AnalysisRunner(transport: context.transport)

        let outcome: AnalysisOutcome
        let started = ContinuousClock.now
        switch feature {
        case .adDetection:
            let request = try AdAnalysisRequest(json: fixture)
            let policy = AdDetectionAnalysisPolicy.service.with(model: entry)
            let window = AdWindowing.windows(of: request, policy: policy.settings).first ?? request
            let payload = AdCanonicalPayload.payload(window, policy: policy.settings, maxOutputTokens: entry.maxOutputTokens, thinking: entry.thinking)
            let count = await context.transport.countTokens(feature: feature, model: entry, payload: payload, thinking: entry.thinking)
            try Self.write(Self.countJSON(count), to: context.out.appending(path: "input-count.json"), key: context.key)
            outcome = await runner.detectAds(request, policy: policy)
        case .chaptersSummary:
            let request = try TranscriptAnalysisRequest(json: fixture)
            let policy = ChaptersSummaryAnalysisPolicy.service.with(model: entry)
            guard case .success(let prepared) = ChaptersPreparation.prepare(request, policy: policy.settings) else {
                throw AnalysisReplay.InputError(description: "transcript too long")
            }
            let thinking = ChaptersCanonicalPayload.baseThinking(modelSegmentCount: prepared.modelRequest.segments.count, model: entry, policy: policy.settings)
            let payload = ChaptersCanonicalPayload.payload(prepared.modelRequest, policy: policy.settings, maxOutputTokens: entry.maxOutputTokens, thinking: thinking)
            let count = await context.transport.countTokens(feature: feature, model: entry, payload: payload, thinking: thinking)
            try Self.write(Self.countJSON(count), to: context.out.appending(path: "input-count.json"), key: context.key)
            outcome = await runner.generateChapters(request, policy: policy)
        }
        let elapsed = started.duration(to: .now)
        let sends = context.sends.sends
        var members = [
            JSONMember("feature", .string(feature.rawValue)),
            JSONMember("provider", .string(entry.provider.rawValue)),
            JSONMember("model", .string(entry.modelID)),
            JSONMember("thinking", .string(entry.thinking)),
            JSONMember("seconds", .double(RecordingHTTPClient.milliseconds(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18))),
        ]
        switch outcome {
        case .adDetection(let response):
            members.append(JSONMember("outcome", .string("ad_detection")))
            members.append(JSONMember("response", response.jsonValue))
        case .chaptersSummary(let response):
            members.append(JSONMember("outcome", .string("chapters_summary")))
            members.append(JSONMember("response", response.jsonValue))
        case .failed(let failure):
            members.append(JSONMember("outcome", .string("failed")))
            members.append(JSONMember("failure_code", .string(failure.code.rawValue)))
            members.append(JSONMember("error", failure.errorJSON()))
            if !failure.issues.isEmpty { members.append(JSONMember("issues", .array(failure.issues.map(JSONValue.string)))) }
        }
        if let listener = AnalysisProviderFailure.resolve(outcome, sends: sends) {
            members.append(JSONMember("listener_failure", .string(listener.rawValue)))
        }
        if let refusal = context.client.refusal { members.append(JSONMember("send_refused", .string(refusal))) }
        members.append(JSONMember("sends", .array(sends.map(Self.sendJSON))))
        let value = JSONValue.object(members)
        try Self.write(value, to: context.out.appending(path: "outcome.json"), key: context.key)
        let printed = JSONValue.object(members.filter { $0.key != "response" && $0.key != "sends" } + [JSONMember("send_count", .integer(sends.count))])
        return try JSONParser.parse(context.key.safeRecording(printed).text)
    }

    static func countJSON(_ count: AnalysisTokenCount) -> JSONValue {
        .object(["input_tokens": .integer(count.tokens), "input_estimated": .bool(count.isEstimated)])
    }

    static func sendJSON(_ send: AnalysisProviderSendRecord) -> JSONValue {
        var members = [
            JSONMember("purpose", .string("\(send.purpose)")),
            JSONMember("send_index", .integer(send.sendIndex)),
            JSONMember("status", send.status.map { .integer($0) } ?? .null),
            JSONMember("finish_reason", send.finishReason.map { .string($0.rawValue) } ?? .null),
            JSONMember("failure", send.failure.map { .string($0.rawValue) } ?? .null),
            JSONMember("paced_s", .double(RecordingHTTPClient.milliseconds(send.pacedSeconds))),
            JSONMember("exchange_s", .double(RecordingHTTPClient.milliseconds(send.exchangeSeconds))),
        ]
        if let usage = send.usage {
            members.append(JSONMember("usage", .object([
                "input": .number(.unsigned(usage.input)), "cached": .number(.unsigned(usage.cached)),
                "write": .number(.unsigned(usage.write)), "output": .number(.unsigned(usage.output)),
                "reasoning": .number(.unsigned(usage.reasoning)),
            ])))
        }
        return .object(members)
    }

    /// Writes one artifact through the recorder sink (redacted by structure,
    /// verified for every fragment of the key, or a placeholder) and returns
    /// what was written, which is also all the tool prints.
    @discardableResult
    static func write(_ value: JSONValue, to url: URL, key: AnalysisProviderKey) throws -> JSONValue {
        let recording = key.safeRecording(value)
        try Data((recording.text + "\n").utf8).write(to: url)
        return try JSONParser.parse(recording.text)
    }
}
