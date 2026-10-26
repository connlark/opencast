import OpenCastAnalysis

/// Classifies a non-2xx Gemini exchange. A 429 whose structured quota
/// details settle the interval is read from them first (``QuotaDetails``):
/// a per-minute limit is a rate limit to pace, a per-day limit is final and
/// named as such. Every other exchange takes the pipeline-facing error from
/// ``GeminiErrorClassifier`` unchanged (the analysis services' rules), and
/// the listener-facing case from the error envelope's status, message and
/// detail reasons.
public enum GeminiProviderErrors {
    public static func classify(status: Int, retryAfter: String?, body: String) -> AnalysisProviderErrorClassification {
        // The provider bound holds for error bodies too: one nested past it
        // is classified by its status alone.
        let body = ProviderJSON.refusesBody(body) ? "" : body
        if status == 429, let quota = QuotaDetails(body) {
            switch quota.interval {
            case .minute:
                // A readable Retry-After header wins; RetryInfo otherwise.
                let delay = retryAfter.flatMap(GeminiErrorClassifier.retryAfterSeconds) ?? quota.retryDelaySeconds
                return AnalysisProviderErrorClassification(transport: .retryable(status: 429, retryAfterSeconds: delay), listener: .rateLimited)
            case .day:
                return AnalysisProviderErrorClassification(transport: .quotaExhausted, listener: .dailyLimit)
            }
        }
        let transport = GeminiErrorClassifier.error(status: status, retryAfter: retryAfter, body: body)
        return AnalysisProviderErrorClassification(transport: transport, listener: listener(status, transport, body))
    }

    /// The quota interval a 429 names in its `google.rpc` error details, read
    /// only when the whole envelope is readable and the interval unambiguous:
    /// the status is `RESOURCE_EXHAUSTED`, the message (when present) is a
    /// string, every detail is an object with a string `@type`, at least one
    /// `QuotaFailure` lists violations, and every violation is an object whose
    /// string `quotaId` names exactly one of `PerMinute` and `PerDay`. Any
    /// per-day violation makes it a daily limit, whatever the others say or
    /// `RetryInfo` suggests. A field that is present must be readable: an
    /// unreadable `quotaValue`, `retryDelay` or `ErrorInfo.reason` is a
    /// malformed shape, not an absent one. `nil`, leaving the services'
    /// classification, for every shape that is not all of the above, for a
    /// zero allocation (`quotaValue` 0, or "limit: 0" in the message: the
    /// model needs billing), and for an `ErrorInfo` reason about billing.
    struct QuotaDetails {
        enum Interval {
            case minute
            case day
        }

        var interval: Interval
        /// The longest `RetryInfo.retryDelay`, rounded up to whole seconds and
        /// capped like `Retry-After`.
        var retryDelaySeconds: Int?

        init?(_ body: String) {
            guard let error = ProviderJSON.parse(body)?["error"],
                  error["status"]?.stringValue == "RESOURCE_EXHAUSTED",
                  let details = error["details"]?.arrayValue
            else {
                return nil
            }
            var message = ""
            if !ProviderJSON.isAbsent(error["message"]) {
                guard let text = error["message"]?.stringValue else { return nil }
                message = ProviderJSON.lowercasedASCII(text)
            }
            guard !message.contains("limit: 0") else { return nil }
            var intervals: [Interval] = []
            var delay: Int?
            for detail in details {
                guard case .object = detail, let type = detail["@type"]?.stringValue else { return nil }
                switch type {
                case "type.googleapis.com/google.rpc.QuotaFailure":
                    guard let violations = detail["violations"]?.arrayValue, !violations.isEmpty else { return nil }
                    for violation in violations {
                        guard case .object = violation,
                              let quotaID = violation["quotaId"]?.stringValue,
                              let allocation = Self.allocation(violation["quotaValue"]), allocation != 0
                        else {
                            return nil
                        }
                        switch (quotaID.contains("PerMinute"), quotaID.contains("PerDay")) {
                        case (true, false): intervals.append(.minute)
                        case (false, true): intervals.append(.day)
                        default: return nil
                        }
                    }
                case "type.googleapis.com/google.rpc.RetryInfo":
                    if !ProviderJSON.isAbsent(detail["retryDelay"]) {
                        guard let seconds = detail["retryDelay"]?.stringValue.flatMap(Self.retryDelaySeconds) else { return nil }
                        delay = max(delay ?? 0, seconds)
                    }
                case "type.googleapis.com/google.rpc.ErrorInfo":
                    if !ProviderJSON.isAbsent(detail["reason"]) {
                        guard let reason = detail["reason"]?.stringValue else { return nil }
                        if ProviderJSON.lowercasedASCII(reason).contains("billing") { return nil }
                    }
                default:
                    continue
                }
            }
            guard !intervals.isEmpty else { return nil }
            interval = intervals.contains(.day) ? .day : .minute
            retryDelaySeconds = delay
        }

        /// A violation's `quotaValue`, an int64 sent as a string or a number:
        /// `UInt64.max` stands in for an absent or null value (it is above
        /// every int64, so no present value can be mistaken for it); `nil`
        /// for a present value that is not a whole number from 0 to
        /// `Int64.max`, which is unreadable, not absent.
        static func allocation(_ value: JSONValue?) -> UInt64? {
            if ProviderJSON.isAbsent(value) { return .max }
            let limit = UInt64(Int64.max)
            if let text = value?.stringValue {
                let digits = text.trimmingCharacters(in: .whitespaces)
                guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                      let parsed = UInt64(digits), parsed <= limit
                else {
                    return nil
                }
                return parsed
            }
            guard let parsed = ProviderJSON.count(value), parsed <= limit else { return nil }
            return parsed
        }

        /// A protobuf duration (`"12s"`, `"7.2s"`, `"0.000340s"`) as whole
        /// seconds rounded up and capped at
        /// ``GeminiErrorClassifier/maxRetryAfterSeconds``; a duration too
        /// large to read caps too. `nil` when it is not a non-negative
        /// duration.
        static func retryDelaySeconds(_ text: String) -> Int? {
            guard text.hasSuffix("s") else { return nil }
            let parts = text.dropLast().split(separator: ".", omittingEmptySubsequences: false)
            let isDigits = { (part: Substring) in !part.isEmpty && part.utf8.allSatisfy { (0x30...0x39).contains($0) } }
            guard (1...2).contains(parts.count), isDigits(parts[0]) else { return nil }
            var roundsUp = false
            if parts.count == 2 {
                guard isDigits(parts[1]), parts[1].count <= 9 else { return nil }
                roundsUp = parts[1].utf8.contains { $0 != 0x30 }
            }
            let cap = UInt64(GeminiErrorClassifier.maxRetryAfterSeconds)
            // Capped before the rounding step, so no value can wrap.
            let whole = min(UInt64(parts[0]) ?? cap, cap)
            return Int(min(whole + (roundsUp ? 1 : 0), cap))
        }
    }

    private static func listener(_ status: Int, _ transport: AnalysisTransportError, _ body: String) -> AnalysisProviderFailure {
        switch transport {
        case .quotaExhausted:
            return .billingOrQuota
        case .retryable(let status, _):
            return status == 429 ? .rateLimited : .overloaded
        default:
            break
        }
        let envelope = Envelope(body)
        switch status {
        case 400:
            if envelope.reasons.contains(where: { $0 == "API_KEY_INVALID" || $0 == "API_KEY_EXPIRED" })
                || envelope.message.contains("api key") {
                return .invalidKey
            }
            return envelope.message.contains("model") ? .modelUnavailable : .requestRejected
        case 401:
            return .invalidKey
        case 403:
            return envelope.message.contains("billing") || envelope.reasons.contains("BILLING_DISABLED")
                ? .billingOrQuota
                : .invalidKey
        case 404:
            return .modelUnavailable
        default:
            return .requestRejected
        }
    }

    /// `{"error": {"message", "status", "details": [{"reason"}]}}`, read
    /// leniently; the message lowercased.
    struct Envelope {
        var message = ""
        var reasons: [String] = []

        init(_ body: String) {
            guard let error = ProviderJSON.parse(body)?["error"] else { return }
            message = ProviderJSON.lowercasedASCII(error["message"]?.stringValue ?? "")
            reasons = (error["details"]?.arrayValue ?? []).compactMap { $0["reason"]?.stringValue }
        }
    }
}
