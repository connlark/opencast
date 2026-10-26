import Foundation
import OpenCastAnalysis

/// Sends canonical payloads to the OpenAI Responses API with the listener's
/// key, mapped by ``OpenAIResponsesMapping``, and returns the answer already
/// reduced to the provider-neutral form.
public struct OpenAIAnalysisTransport: AnalysisKeyedTransport {
    public var provider: AnalysisProvider { .openai }

    private let urls: AnalysisProviderURLs
    private let key: AnalysisProviderKey
    private let exchange: AnalysisProviderExchange

    /// - Parameters:
    ///   - endpoint: The bundle's `providers.openai`; refused unless it is
    ///     `https` on the pinned host with bearer authentication.
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
        urls = try AnalysisProviderURLs(provider: .openai, endpoint: endpoint)
        self.key = key
        exchange = AnalysisProviderExchange(
            provider: .openai,
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
            classify: OpenAIProviderErrors.classify
        )
    }

    /// `POST {base}{generatePath}` with bearer authentication and the mapped
    /// Responses body; `nil` when the payload cannot be mapped.
    public func generateRequest(_ request: AnalysisProviderRequest) -> AnalysisHTTPRequest? {
        guard AnalysisProviderURLs.isValidModelID(request.model.modelID),
              let url = urls.url(path: urls.endpoint.generatePath, modelID: request.model.modelID),
              let body = OpenAIResponsesMapping.body(for: request)
        else {
            return nil
        }
        return AnalysisHTTPRequest(method: "POST", url: url, headers: jsonHeaders, body: Data(JSONWriter.string(body).utf8))
    }

    public func countTokens(
        feature: AnalysisFeature,
        model: AnalysisModelEntry,
        payload: JSONValue,
        thinking: String?
    ) async -> AnalysisTokenCount {
        guard let body = OpenAIResponsesMapping.body(feature: feature, model: model, payload: payload, thinking: thinking) else {
            return AnalysisTokenCount.estimate(bytes: JSONWriter.byteCount(payload))
        }
        let estimate = AnalysisTokenCount.estimate(bytes: JSONWriter.byteCount(body))
        guard let url = urls.url(path: urls.endpoint.countTokensPath, modelID: model.modelID) else {
            return estimate
        }
        let countBody = JSONWriter.string(OpenAIResponsesMapping.countBody(body))
        let http = AnalysisHTTPRequest(method: "POST", url: url, headers: jsonHeaders, body: Data(countBody.utf8))
        guard case .success(let reply) = await exchange.auxiliary(http),
              (200..<300).contains(reply.status),
              let tokens = ProviderJSON.count(ProviderJSON.parse(reply.text)?["input_tokens"]),
              let count = Int(exactly: tokens)
        else {
            return estimate
        }
        return AnalysisTokenCount(tokens: count, isEstimated: false)
    }

    /// `GET {base}/models`: free, and it proves the key.
    public func testKey(model: AnalysisModelEntry) async -> AnalysisKeyTestResult {
        guard let url = urls.url(path: "/models", modelID: nil) else { return .failed(.requestRejected) }
        let http = AnalysisHTTPRequest(method: "GET", url: url, headers: authorizationHeaders, body: nil)
        switch await exchange.auxiliary(http) {
        case .failure(let classification):
            return .failed(classification.listener)
        case .success(let reply):
            guard !(200..<300).contains(reply.status) else { return .accepted }
            return .failed(OpenAIProviderErrors.classify(status: reply.status, retryAfter: reply.retryAfter, body: reply.text).listener)
        }
    }

    private var authorizationHeaders: [AnalysisHTTPHeader] {
        [AnalysisHTTPHeader("authorization", "Bearer \(key.value)")] + urls.versionHeaders
    }

    private var jsonHeaders: [AnalysisHTTPHeader] {
        [AnalysisHTTPHeader("authorization", "Bearer \(key.value)"), AnalysisHTTPHeader("content-type", "application/json")]
            + urls.versionHeaders
    }

    static func interpret(_ text: String) -> AnalysisProviderInterpretation {
        let (answer, billed) = OpenAIResponsesMapping.answer(fromBody: text)
        return AnalysisProviderInterpretation(reply: .answer(answer), finishReason: AnalysisFinishReason.normalized(answer.finishReason), usage: billed)
    }
}

extension OpenAIAnalysisTransport: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "OpenAIAnalysisTransport(host: \(provider.pinnedHost))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider.rawValue]) }
}
