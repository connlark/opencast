import OpenCastAnalysis

/// Classifies a non-2xx OpenAI exchange for the pipeline and the listener.
/// 401 is an invalid key; 404 (or a 400/403 naming the model) an
/// unavailable model; 429 `insufficient_quota` the account's quota or
/// prepaid balance; any other 429 a rate limit to retry after
/// `Retry-After`; 500, 502, 503, 504 and 529 an overloaded provider to
/// retry; everything else a final refusal. `Retry-After` is read as Gemini's
/// is: whole seconds, capped.
public enum OpenAIProviderErrors {
    public static func classify(status: Int, retryAfter: String?, body: String) -> AnalysisProviderErrorClassification {
        let envelope = Envelope(body)
        let retry = retryAfter.flatMap(GeminiErrorClassifier.retryAfterSeconds)
        switch status {
        case 401:
            return .init(transport: .rejected(status: status), listener: .invalidKey)
        case 404:
            return .init(transport: .rejected(status: status), listener: .modelUnavailable)
        case 429:
            if envelope.code == "insufficient_quota" || envelope.type == "insufficient_quota" {
                return .init(transport: .quotaExhausted, listener: .billingOrQuota)
            }
            return .init(transport: .retryable(status: status, retryAfterSeconds: retry), listener: .rateLimited)
        case 500, 502, 503, 504, 529:
            return .init(transport: .retryable(status: status, retryAfterSeconds: retry), listener: .overloaded)
        case 400, 403:
            if envelope.code == "model_not_found" || envelope.param == "model" {
                return .init(transport: .rejected(status: status), listener: .modelUnavailable)
            }
            if status == 403, envelope.code != "unsupported_country_region_territory" {
                return .init(transport: .rejected(status: status), listener: .invalidKey)
            }
            return .init(transport: .rejected(status: status), listener: .requestRejected)
        default:
            return .init(transport: .rejected(status: status), listener: .requestRejected)
        }
    }

    /// `{"error": {"code", "type", "param"}}`, read leniently. The message
    /// is never read.
    struct Envelope {
        var code: String?
        var type: String?
        var param: String?

        init(_ body: String) {
            guard let error = ProviderJSON.parse(body)?["error"] else { return }
            code = error["code"]?.stringValue
            type = error["type"]?.stringValue
            param = error["param"]?.stringValue
        }
    }
}
