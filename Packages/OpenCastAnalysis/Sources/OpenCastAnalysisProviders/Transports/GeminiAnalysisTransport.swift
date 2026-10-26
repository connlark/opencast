import Foundation
import OpenCastAnalysis

/// Sends canonical payloads to Gemini `generateContent` with the listener's
/// key. The canonical payload is already Gemini's wire shape, so the body is
/// the request's `payloadText`, byte for byte, and the reply is the raw body
/// for the pipeline to parse as the services do.
public struct GeminiAnalysisTransport: AnalysisKeyedTransport {
    public var provider: AnalysisProvider { .google }

    private let urls: AnalysisProviderURLs
    private let key: AnalysisProviderKey
    private let exchange: AnalysisProviderExchange

    /// - Parameters:
    ///   - endpoint: The bundle's `providers.google`; refused unless it is
    ///     `https` on the pinned host with the `x-goog-api-key` style.
    ///   - pacer: The key's session pacer; `nil` sends unpaced.
    ///   - observer: Receives a record of every send.
    ///   - preDispatch: Runs after the pacer admits each send, right before
    ///     it leaves; a refusal fails the send unsent.
    public init(
        endpoint: AnalysisProviderEndpoint,
        key: AnalysisProviderKey,
        client: any AnalysisHTTPClient = URLSessionAnalysisHTTPClient(),
        pacer: AnalysisKeyPacer? = nil,
        observer: (any AnalysisProviderSendObserver)? = nil,
        logger: RedactingLogger = RedactingLogger(),
        clock: any AnalysisClock = AnalysisSystemClock(),
        preDispatch: AnalysisPreDispatchCheck? = nil
    ) throws(AnalysisProviderConfigurationError) {
        urls = try AnalysisProviderURLs(provider: .google, endpoint: endpoint)
        self.key = key
        exchange = AnalysisProviderExchange(
            provider: .google,
            client: client,
            pacer: pacer,
            observer: observer,
            logger: logger.redacting(key.value),
            clock: clock,
            verifier: SecretVerifier(secrets: [key.value]),
            preDispatch: preDispatch
        )
    }

    public func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        try await exchange.send(
            request,
            http: generateRequest(request),
            interpret: Self.interpret,
            classify: GeminiProviderErrors.classify
        )
    }

    /// The exact `generateContent` exchange: `POST {base}{generatePath}` with
    /// `{model}` = the entry's model id, headers `content-type:
    /// application/json` and `x-goog-api-key` (plus the bundle's version
    /// headers), body = `payloadText`. A key-injecting proxy forwards these
    /// bytes unchanged.
    public func generateRequest(_ request: AnalysisProviderRequest) -> AnalysisHTTPRequest? {
        guard let url = urls.url(path: urls.endpoint.generatePath, modelID: request.model.modelID) else { return nil }
        return AnalysisHTTPRequest(method: "POST", url: url, headers: headers, body: Data(request.payloadText.utf8))
    }

    public func countTokens(
        feature: AnalysisFeature,
        model: AnalysisModelEntry,
        payload: JSONValue,
        thinking: String?
    ) async -> AnalysisTokenCount {
        let estimate = AnalysisTokenCount.estimate(bytes: JSONWriter.byteCount(payload))
        guard let url = urls.url(path: urls.endpoint.countTokensPath, modelID: model.modelID),
              case .object(let members) = payload
        else {
            return estimate
        }
        let body = JSONValue.object([
            JSONMember("generateContentRequest", .object(
                [JSONMember("model", .string("models/\(model.modelID)"))] + members
            )),
        ])
        let http = AnalysisHTTPRequest(method: "POST", url: url, headers: headers, body: Data(JSONWriter.string(body).utf8))
        guard case .success(let reply) = await exchange.auxiliary(http),
              (200..<300).contains(reply.status),
              let tokens = ProviderJSON.count(ProviderJSON.parse(reply.text)?["totalTokens"]),
              let count = Int(exactly: tokens)
        else {
            return estimate
        }
        return AnalysisTokenCount(tokens: count, isEstimated: false)
    }

    /// `countTokens` on the entry's model with a one-word prompt: free, and
    /// it proves both the key and the model.
    public func testKey(model: AnalysisModelEntry) async -> AnalysisKeyTestResult {
        guard let url = urls.url(path: urls.endpoint.countTokensPath, modelID: model.modelID) else {
            return .failed(.modelUnavailable)
        }
        let body = #"{"contents":[{"parts":[{"text":"ping"}],"role":"user"}]}"#
        let http = AnalysisHTTPRequest(method: "POST", url: url, headers: headers, body: Data(body.utf8))
        switch await exchange.auxiliary(http) {
        case .failure(let classification):
            return .failed(classification.listener)
        case .success(let reply):
            guard !(200..<300).contains(reply.status) else { return .accepted }
            return .failed(GeminiProviderErrors.classify(status: reply.status, retryAfter: reply.retryAfter, body: reply.text).listener)
        }
    }

    private var headers: [AnalysisHTTPHeader] {
        [AnalysisHTTPHeader("content-type", "application/json"), AnalysisHTTPHeader("x-goog-api-key", key.value)]
            + urls.versionHeaders
    }

    /// The 2xx body goes to the pipeline byte for byte when every candidate's
    /// `finishReason` is one Gemini documents (the services read the same
    /// bytes). A finish reason Gemini does not document is provider text the
    /// pipeline would copy into a response's warnings, so that body goes on
    /// with those values, and only those, replaced by `MALFORMED_RESPONSE`
    /// (still not `STOP`, so the answer fails as before). The record reads the
    /// same finish reason and the billed usage (input, cached, output =
    /// candidates + thoughts, reasoning = thoughts; absent unless both prompt
    /// and candidate counts are present).
    static func interpret(_ text: String) -> AnalysisProviderInterpretation {
        // The provider bound holds for the body and for the answer texts in
        // it, which the pipeline parses next: a body refused by the bound, or
        // one whose answer texts nest past it, is a malformed answer instead.
        let malformed = AnalysisProviderInterpretation(
            reply: .answer(AnalysisProviderAnswer(texts: [], finishReason: AnalysisFinishReason.malformedResponse.rawValue, usage: nil)),
            finishReason: .malformedResponse,
            usage: nil
        )
        guard !ProviderJSON.refusesBody(text) else { return malformed }
        let root = ProviderJSON.parse(text)
        let answers = (root?["candidates"]?.arrayValue ?? []).map { candidate in
            (candidate["content"]?["parts"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        }
        guard !answers.contains(where: ProviderJSON.answerTooDeep) else { return malformed }
        let forwarded = root.flatMap(Self.replacingUndocumentedFinishReasons) ?? text
        let candidates = root?["candidates"]?.arrayValue ?? []
        let finishReason = candidates.count == 1 ? AnalysisFinishReason.gemini(candidates[0]["finishReason"]?.stringValue) : nil
        var usage: AnalysisBilledUsage?
        if let metadata = root?["usageMetadata"],
           let prompt = ProviderJSON.count(metadata["promptTokenCount"]),
           let candidatesTokens = ProviderJSON.count(metadata["candidatesTokenCount"]) {
            let thoughts = ProviderJSON.count(metadata["thoughtsTokenCount"]) ?? 0
            usage = AnalysisBilledUsage(
                input: prompt,
                cached: ProviderJSON.count(metadata["cachedContentTokenCount"]) ?? 0,
                write: 0,
                output: ProviderJSON.saturatingAdd(candidatesTokens, thoughts),
                reasoning: thoughts
            )
        }
        return AnalysisProviderInterpretation(reply: .geminiBody(forwarded), finishReason: finishReason, usage: usage)
    }

    /// `root` written out again with every candidate `finishReason` string
    /// Gemini does not document replaced by `MALFORMED_RESPONSE`; `nil` when
    /// there is none, so the original bytes go on unchanged.
    static func replacingUndocumentedFinishReasons(_ root: JSONValue) -> String? {
        guard case .object(let members) = root else { return nil }
        var replaced = false
        let rewritten = members.map { member -> JSONMember in
            guard member.key == "candidates", case .array(let candidates) = member.value else { return member }
            return JSONMember(member.key, .array(candidates.map { candidate -> JSONValue in
                guard case .object(let fields) = candidate else { return candidate }
                return .object(fields.map { field -> JSONMember in
                    guard field.key == "finishReason", case .string(let value) = field.value,
                          !AnalysisFinishReason.geminiVocabulary.contains(value)
                    else {
                        return field
                    }
                    replaced = true
                    return JSONMember(field.key, .string(AnalysisFinishReason.malformedResponse.rawValue))
                })
            }))
        }
        return replaced ? JSONWriter.string(.object(rewritten)) : nil
    }
}

extension GeminiAnalysisTransport: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "GeminiAnalysisTransport(host: \(provider.pinnedHost))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider.rawValue]) }
}
