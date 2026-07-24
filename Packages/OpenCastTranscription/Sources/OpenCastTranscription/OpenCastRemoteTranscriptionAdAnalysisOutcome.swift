/// Top-level `ad_analysis` block of the result envelope, present only on jobs
/// created with `adAnalysisRequested`. Decoding keys off `state`; a state this
/// client does not know is preserved as `.unknown` and treated as a failed
/// analysis (device fallback) — never as skippable audio.
public enum OpenCastRemoteTranscriptionAdAnalysisOutcome: Sendable, Equatable {
    case completed(OpenCastRemoteTranscriptionAdAnalysisSuccess)
    case failed(errorCode: String?)
    case unknown(state: String)
}

extension OpenCastRemoteTranscriptionAdAnalysisOutcome: Codable {
    enum CodingKeys: String, CodingKey {
        case state
        case errorCode = "error_code"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case "completed":
            self = .completed(try OpenCastRemoteTranscriptionAdAnalysisSuccess(from: decoder))
        case "failed":
            self = .failed(
                errorCode: try container.decodeIfPresent(String.self, forKey: .errorCode)
            )
        default:
            self = .unknown(state: state)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .completed(success):
            try container.encode("completed", forKey: .state)
            try success.encode(to: encoder)
        case let .failed(errorCode):
            try container.encode("failed", forKey: .state)
            try container.encodeIfPresent(errorCode, forKey: .errorCode)
        case let .unknown(state):
            try container.encode(state, forKey: .state)
        }
    }
}
