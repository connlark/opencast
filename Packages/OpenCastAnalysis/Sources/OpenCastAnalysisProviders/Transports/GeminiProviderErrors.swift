import OpenCastAnalysis

/// A 429 whose quota details settle the interval: per minute is a rate limit to pace, per day
/// is final. Every other pipeline-facing error is ``GeminiErrorClassifier``'s, the analysis
/// services' rules, unchanged.
public enum GeminiProviderErrors {
    /// With `freeTierIsFinal`, a free-tier answer becomes `.quotaExhausted`: neither retried nor
    /// paced.
    public static func classify(
        status: Int,
        retryAfter: String?,
        body: String,
        freeTierIsFinal: Bool = false
    ) -> AnalysisProviderErrorClassification {
        // An error body past the provider bound is classified by its status alone.
        let body = ProviderJSON.refusesBody(body) ? "" : body
        var classification = classifyExchange(status: status, retryAfter: retryAfter, body: body)
        classification.freeTier = namesFreeTier(status: status, body: body)
        if classification.freeTier, freeTierIsFinal {
            classification.transport = .quotaExhausted
        }
        return classification
    }

    /// Free-tier refusals say "limit: 0" and carry no `quotaValue`, so no interval or allocation
    /// is needed. The envelope must still be fully readable: this answer can move a run off the
    /// listener's key.
    public static func namesFreeTier(status: Int, body: String) -> Bool {
        guard status == 429, !ProviderJSON.refusesBody(body),
              let error = ProviderJSON.parse(body)?["error"],
              error["status"]?.stringValue == "RESOURCE_EXHAUSTED",
              ProviderJSON.isAbsent(error["message"]) || error["message"]?.stringValue != nil,
              let details = error["details"]?.arrayValue
        else {
            return false
        }
        var named = false
        for detail in details {
            guard case .object = detail, let type = detail["@type"]?.stringValue else { return false }
            guard type == "type.googleapis.com/google.rpc.QuotaFailure" else { continue }
            guard let violations = detail["violations"]?.arrayValue else { return false }
            for violation in violations {
                guard case .object = violation else { return false }
                if violation["quotaId"]?.stringValue?.contains("FreeTier") == true
                    || violation["quotaMetric"]?.stringValue?.contains("free_tier") == true {
                    named = true
                }
            }
        }
        return named
    }

    private static func classifyExchange(status: Int, retryAfter: String?, body: String) -> AnalysisProviderErrorClassification {
        if status == 429, let quota = QuotaDetails(body) {
            switch quota.interval {
            case .minute:
                let delay = retryAfter.flatMap(GeminiErrorClassifier.retryAfterSeconds) ?? quota.retryDelaySeconds
                return AnalysisProviderErrorClassification(transport: .retryable(status: 429, retryAfterSeconds: delay), listener: .rateLimited)
            case .day:
                return AnalysisProviderErrorClassification(transport: .quotaExhausted, listener: .dailyLimit)
            }
        }
        let transport = GeminiErrorClassifier.error(status: status, retryAfter: retryAfter, body: body)
        return AnalysisProviderErrorClassification(transport: transport, listener: listener(status, transport, body))
    }

    /// Read only from a fully readable envelope: a present but unreadable field is malformed, not
    /// absent. A zero allocation (`quotaValue` 0 or "limit: 0": the model needs billing) or a
    /// billing reason gives `nil`, leaving the services' classification.
    struct QuotaDetails {
        enum Interval {
            case minute
            case day
        }

        var interval: Interval
        /// Whole seconds: the longest `RetryInfo.retryDelay`, capped like `Retry-After`.
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

        /// `UInt64.max`, above every int64, stands in for an absent value; `nil` means present but
        /// unreadable.
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

        /// A protobuf duration (`"7.2s"`) in whole seconds, rounded up and capped; one too large to
        /// read caps too.
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
