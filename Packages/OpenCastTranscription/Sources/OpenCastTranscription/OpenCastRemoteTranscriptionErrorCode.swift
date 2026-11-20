public enum OpenCastRemoteTranscriptionErrorCode: Sendable, Equatable, Hashable {
    case sourceMismatch
    case unsupportedMediaType
    case sourceTooLarge
    case durationTooLong
    case originFetchFailed
    case insufficientCredits
    case deadlineExpired
    case jobNotFound
    case accountMismatch
    case featureDisabled
    case bootstrapRequired
    case purchasesDisabled
    case unauthorized
    case rateLimited
    case invalidRequest
    case transcriptionFailed
    case cancelled
    case internalError
    case uploadUnavailable
    case uploadIdentityMismatch
    case unknown(String)

    public init(wireValue: String) {
        self = Self.known[wireValue] ?? .unknown(wireValue)
    }

    public var wireValue: String {
        switch self {
        case .sourceMismatch: "remote_unavailable_source_mismatch"
        case .unsupportedMediaType: "unsupported_media_type"
        case .sourceTooLarge: "source_too_large"
        case .durationTooLong: "duration_too_long"
        case .originFetchFailed: "origin_fetch_failed"
        case .insufficientCredits: "insufficient_credits"
        case .deadlineExpired: "deadline_expired"
        case .jobNotFound: "job_not_found"
        case .accountMismatch: "account_mismatch"
        case .featureDisabled: "feature_disabled"
        case .bootstrapRequired: "bootstrap_required"
        case .purchasesDisabled: "purchases_disabled"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate_limited"
        case .invalidRequest: "invalid_request"
        case .transcriptionFailed: "transcription_failed"
        case .cancelled: "cancelled"
        case .internalError: "internal_error"
        case .uploadUnavailable: "upload_unavailable"
        case .uploadIdentityMismatch: "upload_identity_mismatch"
        case let .unknown(value): value
        }
    }

    private static let known: [String: Self] = {
        let cases: [Self] = [
            .sourceMismatch, .unsupportedMediaType, .sourceTooLarge,
            .durationTooLong, .originFetchFailed, .insufficientCredits,
            .deadlineExpired, .jobNotFound, .accountMismatch, .featureDisabled,
            .bootstrapRequired, .purchasesDisabled,
            .unauthorized, .rateLimited, .invalidRequest, .transcriptionFailed,
            .cancelled, .internalError, .uploadUnavailable,
            .uploadIdentityMismatch,
        ]
        return Dictionary(uniqueKeysWithValues: cases.map { ($0.wireValue, $0) })
    }()
}

extension OpenCastRemoteTranscriptionErrorCode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
