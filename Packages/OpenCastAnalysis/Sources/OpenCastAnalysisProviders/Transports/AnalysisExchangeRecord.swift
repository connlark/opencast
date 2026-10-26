import Foundation
import OpenCastAnalysis

/// What a recorder keeps of one provider exchange: structured fields only,
/// never a provider string it has not read into a closed vocabulary, a
/// number or the answer itself.
///
/// - Response, every status: the status code, the content type (a closed
///   set), the parsed `Retry-After` seconds.
/// - 2xx `generate`: the answer text only (Gemini: each candidate's
///   non-thought text parts and its finish reason; OpenAI: the
///   `output_text` parts and the mapped finish reason), each text verified
///   with the full contract or replaced by a placeholder; the usage
///   numbers the pipeline and the ledger read.
/// - 2xx `count`: the token count. 2xx `key_test`: nothing more.
/// - Non-2xx: the classification (transport error and listener failure,
///   closed vocabularies); the error `status`, detail reasons (Gemini) or
///   `type`, `code` and `param` (OpenAI) when in the known set per provider,
///   otherwise `unknown`; the quota ids that matched the per-minute or
///   per-day rule and the parsed retry delay. Never the message.
/// - Request: the kind, the body size and the body the transport built
///   (the pipeline's canonical payload in the provider's shape), verified
///   whole or replaced by a placeholder; never the URL or a header.
///
/// Everything else in a body is dropped. The record is then verified as a
/// whole artifact before it is written.
public enum AnalysisExchangeRecord {
    public enum Kind: String, Sendable {
        case generate
        case count
        case keyTest = "key_test"
    }

    public static func kind(of request: AnalysisHTTPRequest) -> Kind {
        let path = request.url.path(percentEncoded: false)
        if request.method == "GET" { return .keyTest }
        if path.hasSuffix(":countTokens") || path.hasSuffix("/input_tokens") { return .count }
        return .generate
    }

    // MARK: Request

    public static func request(_ request: AnalysisHTTPRequest, key: AnalysisProviderKey) -> JSONValue {
        let kind = kind(of: request)
        var members = [JSONMember("kind", .string(kind.rawValue))]
        guard let body = request.body else { return .object(members) }
        members.append(JSONMember("body_bytes", .integer(body.count)))
        let verifier = key.verifier
        switch BoundedJSON.parse(String(decoding: body, as: UTF8.self), maximumDepth: SecretVerifier.maximumJSONDepth) {
        case .value(let json):
            switch verifier.verifyRecordedArtifact(JSONWriter.string(json)) {
            case .clean: members.append(JSONMember("body", json))
            case .secretFragment: members.append(JSONMember("body", placeholder("secret_fragment")))
            case .exhausted: members.append(JSONMember("body", placeholder("verification_bound")))
            }
        case .tooDeep:
            members.append(JSONMember("body", placeholder("verification_bound")))
        case .invalid:
            members.append(JSONMember("body", placeholder("not_json")))
        }
        return .object(members)
    }

    // MARK: Response

    public static func response(
        _ response: AnalysisHTTPResponse,
        provider: AnalysisProvider,
        kind: Kind,
        key: AnalysisProviderKey
    ) -> JSONValue {
        var members = [JSONMember("status", .integer(response.status))]
        if let contentType = response.contentType { members.append(JSONMember("content_type", .string(contentType))) }
        if let seconds = response.retryAfterSeconds { members.append(JSONMember("retry_after_s", .integer(seconds))) }
        guard let text = String(validating: response.body, as: UTF8.self) else {
            members.append(JSONMember("body", .string("not_utf8")))
            return .object(members)
        }
        let verifier = key.verifier
        if (200..<300).contains(response.status) {
            switch kind {
            case .generate:
                members += provider == .google ? geminiAnswer(text, verifier: verifier) : openAIAnswer(text, verifier: verifier)
            case .count:
                let root = ProviderJSON.parse(text)
                if let tokens = ProviderJSON.count(provider == .google ? root?["totalTokens"] : root?["input_tokens"]) {
                    members.append(JSONMember("total_tokens", .number(.unsigned(tokens))))
                }
            case .keyTest:
                break
            }
        } else {
            members += errorFields(text, status: response.status, retryAfter: response.retryAfter, provider: provider)
        }
        return .object(members)
    }

    /// Each candidate's non-thought text parts and finish reason, and the
    /// `usageMetadata` counts. A body that is not a Gemini answer records
    /// only that.
    static func geminiAnswer(_ text: String, verifier: SecretVerifier) -> [JSONMember] {
        guard !ProviderJSON.refusesBody(text), let root = ProviderJSON.parse(text), case .object = root else {
            return [JSONMember("body", .string("not_an_answer"))]
        }
        var members: [JSONMember] = []
        if let candidates = root["candidates"]?.arrayValue {
            members.append(JSONMember("candidates", .array(candidates.map { candidate -> JSONValue in
                var fields: [JSONMember] = []
                if let content = candidate["content"], case .object = content {
                    let parts = content["parts"]?.arrayValue ?? []
                    let texts = parts.filter { $0["thought"] != .bool(true) }.compactMap { $0["text"]?.stringValue }
                    fields.append(JSONMember("texts", .array(texts.map { verified($0, verifier: verifier) })))
                } else {
                    fields.append(JSONMember("texts", .null))
                }
                if let reason = AnalysisFinishReason.gemini(candidate["finishReason"]?.stringValue) {
                    fields.append(JSONMember("finish_reason", .string(reason.rawValue)))
                }
                return .object(fields)
            })))
        }
        if let metadata = root["usageMetadata"] {
            let names = ["promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "totalTokenCount", "cachedContentTokenCount"]
            let counts = names.compactMap { name in ProviderJSON.count(metadata[name]).map { JSONMember(name, .number(.unsigned($0))) } }
            members.append(JSONMember("usage", .object(counts)))
        }
        return members
    }

    /// The `output_text` parts, the mapped finish reason and the billed
    /// usage, as the transport reads them.
    static func openAIAnswer(_ text: String, verifier: SecretVerifier) -> [JSONMember] {
        let (answer, billed) = OpenAIResponsesMapping.answer(fromBody: text)
        var members = [
            JSONMember("texts", .array(answer.texts.map { verified($0, verifier: verifier) })),
            JSONMember("finish_reason", .string(AnalysisFinishReason.normalized(answer.finishReason)?.rawValue
                ?? AnalysisFinishReason.malformedResponse.rawValue)),
        ]
        if let billed {
            members.append(JSONMember("usage", .object([
                JSONMember("input_tokens", .number(.unsigned(billed.input))),
                JSONMember("cached_tokens", .number(.unsigned(billed.cached))),
                JSONMember("cache_write_tokens", .number(.unsigned(billed.write))),
                JSONMember("output_tokens", .number(.unsigned(billed.output))),
                JSONMember("reasoning_tokens", .number(.unsigned(billed.reasoning))),
            ])))
        }
        return members
    }

    static func errorFields(_ text: String, status: Int, retryAfter: String?, provider: AnalysisProvider) -> [JSONMember] {
        let classification = provider == .google
            ? GeminiProviderErrors.classify(status: status, retryAfter: retryAfter, body: text)
            : OpenAIProviderErrors.classify(status: status, retryAfter: retryAfter, body: text)
        var members = [
            JSONMember("transport", .string(transportName(classification.transport))),
            JSONMember("listener", .string(classification.listener.rawValue)),
        ]
        let error = ProviderJSON.refusesBody(text) ? nil : ProviderJSON.parse(text)?["error"]
        func known(_ value: JSONValue?, in set: Set<String>) -> JSONValue? {
            guard let value, value != .null else { return nil }
            guard let string = value.stringValue, set.contains(string) else { return .string("unknown") }
            return .string(string)
        }
        switch provider {
        case .google:
            if let status = known(error?["status"], in: geminiStatuses) { members.append(JSONMember("error_status", status)) }
            let details = error?["details"]?.arrayValue ?? []
            let reasons = details.compactMap { known($0["reason"], in: geminiReasons) }
            if !reasons.isEmpty { members.append(JSONMember("reasons", .array(reasons))) }
            let quotaIDs = details
                .filter { $0["@type"]?.stringValue == "type.googleapis.com/google.rpc.QuotaFailure" }
                .flatMap { $0["violations"]?.arrayValue ?? [] }
                .compactMap { $0["quotaId"]?.stringValue }
                .filter(isRuleQuotaID)
            if !quotaIDs.isEmpty { members.append(JSONMember("quota_ids", .array(quotaIDs.map(JSONValue.string)))) }
            if let delay = ProviderJSON.refusesBody(text) ? nil : GeminiProviderErrors.QuotaDetails(text)?.retryDelaySeconds {
                members.append(JSONMember("retry_delay_s", .integer(delay)))
            }
        case .openai:
            if let type = known(error?["type"], in: openAITypes) { members.append(JSONMember("error_type", type)) }
            if let code = known(error?["code"], in: openAICodes) { members.append(JSONMember("error_code", code)) }
            if let param = known(error?["param"], in: openAIParams) { members.append(JSONMember("error_param", param)) }
        }
        return members
    }

    /// A quota id the per-minute or per-day rule reads: it names exactly one
    /// of the two intervals and is made of letters, digits, `-` and `_`.
    static func isRuleQuotaID(_ id: String) -> Bool {
        (id.contains("PerMinute") != id.contains("PerDay")) && (1...128).contains(id.utf8.count)
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x5F }
    }

    static func verified(_ text: String, verifier: SecretVerifier) -> JSONValue {
        switch verifier.verifyRecordedText(text) {
        case .clean: .string(text)
        case .secretFragment: placeholder("secret_fragment")
        case .exhausted: placeholder("verification_bound")
        }
    }

    static func placeholder(_ reason: String) -> JSONValue {
        .object([JSONMember("redacted", .bool(true)), JSONMember("reason", .string(reason))])
    }

    // MARK: Closed vocabularies

    public static func transportName(_ error: AnalysisTransportError) -> String {
        switch error {
        case .retryable(let status, let seconds): "retryable:\(status):\(seconds.map(String.init) ?? "none")"
        case .quotaExhausted: "quota_exhausted"
        case .rejected(let status): "rejected:\(status)"
        case .timeout: "timeout"
        case .network: "network"
        case .oversizedBody: "oversized_body"
        case .invalidEncoding: "invalid_encoding"
        case .notArchived: "not_archived"
        }
    }

    public static func failureName(_ failure: AnalysisHTTPFailure) -> String {
        switch failure {
        case .timeout: "timeout"
        case .network: "network"
        case .oversizedBody: "oversized_body"
        }
    }

    /// The `google.rpc.Code` names.
    static let geminiStatuses: Set<String> = [
        "INVALID_ARGUMENT", "FAILED_PRECONDITION", "OUT_OF_RANGE", "UNAUTHENTICATED", "PERMISSION_DENIED", "NOT_FOUND",
        "ABORTED", "ALREADY_EXISTS", "RESOURCE_EXHAUSTED", "CANCELLED", "DATA_LOSS", "UNKNOWN", "INTERNAL",
        "NOT_IMPLEMENTED", "UNAVAILABLE", "DEADLINE_EXCEEDED",
    ]
    /// `google.rpc.ErrorInfo` reasons the classifiers read or Google
    /// documents for API keys, billing and quota.
    static let geminiReasons: Set<String> = [
        "API_KEY_INVALID", "API_KEY_EXPIRED", "API_KEY_SERVICE_BLOCKED", "API_KEY_HTTP_REFERRER_BLOCKED",
        "API_KEY_IP_ADDRESS_BLOCKED", "API_KEY_ANDROID_APP_BLOCKED", "API_KEY_IOS_APP_BLOCKED", "BILLING_DISABLED",
        "SERVICE_DISABLED", "CONSUMER_INVALID", "CONSUMER_SUSPENDED", "RATE_LIMIT_EXCEEDED", "RESOURCE_PROJECT_INVALID",
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "USER_PROJECT_DENIED",
    ]
    static let openAITypes: Set<String> = [
        "invalid_request_error", "insufficient_quota", "server_error", "requests", "tokens", "request_forbidden",
        "rate_limit_error", "authentication_error", "permission_error", "not_found_error", "api_error", "overloaded_error",
    ]
    static let openAICodes: Set<String> = [
        "invalid_api_key", "model_not_found", "rate_limit_exceeded", "insufficient_quota",
        "unsupported_country_region_territory", "unsupported_value", "unsupported_parameter", "invalid_value",
        "context_length_exceeded", "server_error", "missing_required_parameter", "invalid_type",
    ]
    /// Request fields the transport sends, as OpenAI names them in `param`.
    static let openAIParams: Set<String> = [
        "model", "reasoning", "reasoning.effort", "max_output_tokens", "text", "text.format", "input", "instructions",
        "store", "include",
    ]
}
