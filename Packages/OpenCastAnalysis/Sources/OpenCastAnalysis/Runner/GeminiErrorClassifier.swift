/// Maps a non-2xx Gemini `generateContent` exchange to the pipeline's
/// provider-neutral transport error, with the analysis services' rules:
/// 500/502/503/504 retry; 429 retries unless the error envelope reports
/// `RESOURCE_EXHAUSTED` with a quota, billing, prepay or credit message
/// (a hard quota); every other status is final. `Retry-After` is honoured
/// only as whole seconds, capped at 30.
public enum GeminiErrorClassifier {
    public static let maxRetryAfterSeconds = 30

    public static func error(status: Int, retryAfter: String?, body: String) -> AnalysisTransportError {
        switch status {
        case 500, 502, 503, 504:
            return .retryable(status: status, retryAfterSeconds: retryAfter.flatMap(retryAfterSeconds))
        case 429:
            if isHardQuota(body) { return .quotaExhausted }
            return .retryable(status: status, retryAfterSeconds: retryAfter.flatMap(retryAfterSeconds))
        default:
            return .rejected(status: status)
        }
    }

    /// An unsigned decimal (an optional `+` allowed), capped; anything else,
    /// including a value too large to read, is ignored.
    public static func retryAfterSeconds(_ value: String) -> Int? {
        var digits = Substring(RustText.trim(value))
        if digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let seconds = UInt64(digits)
        else { return nil }
        return Int(min(seconds, UInt64(maxRetryAfterSeconds)))
    }

    /// The error envelope `{"error": {"code"?, "message"?, "status"?}}` read
    /// strictly; a body that does not have that shape is not a hard quota.
    static func isHardQuota(_ body: String) -> Bool {
        let message: String
        let status: String?
        do {
            let root = try StrictDecoding.fields(try JSONParser.parse(body), .init(fields: ["error"]))
            let error = try StrictDecoding.fields(
                root["error"]!,
                .init(fields: ["code", "message", "status"], defaulted: ["code", "message", "status"])
            )
            // Absent or null codes are fine; a present code must be a u16.
            _ = try StrictDecoding.optional(error["code"]) { value throws(StrictDecodingError) in
                try StrictDecoding.unsigned(value, as: UInt16.self)
            }
            message = try error["message"].map(StrictDecoding.string) ?? ""
            status = try StrictDecoding.optional(error["status"], StrictDecoding.string)
        } catch {
            return false
        }
        let lowered = String(decoding: message.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
        return RustText.same(status, "RESOURCE_EXHAUSTED")
            && ["quota", "billing", "prepay", "credit"].contains { RustText.containsBytes(lowered, $0) }
    }
}
