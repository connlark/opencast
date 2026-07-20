/// Stability classification for the Worker's read-only remaining-time
/// projection. Unknown strings survive round trips so newer server behavior
/// does not break an older polling client.
public enum OpenCastRemoteTranscriptionEstimateStatus: Sendable, Equatable, Hashable {
    case onTrack
    case queued
    case delayed
    case unknown(String)

    public init(wireValue: String) {
        switch wireValue {
        case "on_track": self = .onTrack
        case "queued": self = .queued
        case "delayed": self = .delayed
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .onTrack: "on_track"
        case .queued: "queued"
        case .delayed: "delayed"
        case let .unknown(value): value
        }
    }
}

extension OpenCastRemoteTranscriptionEstimateStatus: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
