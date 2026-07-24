/// Server job states on the wire. Stable strings are the contract; values
/// this client does not know yet are preserved, not dropped.
public enum OpenCastRemoteTranscriptionJobState: Sendable, Equatable, Hashable {
    case created
    case stagingOrigin
    case waitingForDeviceSource
    case sourceMatched
    case exactUploadRequired
    case exactUploading
    case probing
    case awaitingCredits
    case reserved
    case chunking
    case transcribing
    case stitching
    case detectingAds
    case resultReady
    case delivered
    case acknowledged
    case cancelling
    case cancelled
    case failed
    case unknown(String)

    public init(wireValue: String) {
        self = Self.known[wireValue] ?? .unknown(wireValue)
    }

    public var wireValue: String {
        switch self {
        case .created: "created"
        case .stagingOrigin: "staging_origin"
        case .waitingForDeviceSource: "waiting_for_device_source"
        case .sourceMatched: "source_matched"
        case .exactUploadRequired: "exact_upload_required"
        case .exactUploading: "exact_uploading"
        case .probing: "probing"
        case .awaitingCredits: "awaiting_credits"
        case .reserved: "reserved"
        case .chunking: "chunking"
        case .transcribing: "transcribing"
        case .stitching: "stitching"
        case .detectingAds: "detecting_ads"
        case .resultReady: "result_ready"
        case .delivered: "delivered"
        case .acknowledged: "acknowledged"
        case .cancelling: "cancelling"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case let .unknown(value): value
        }
    }

    /// Terminal states never advance again; unknown states are treated as
    /// nonterminal so a newer server cannot strand a polling client.
    public var isTerminal: Bool {
        switch self {
        case .acknowledged, .cancelled, .failed: true
        default: false
        }
    }

    private static let known: [String: Self] = {
        let cases: [Self] = [
            .created, .stagingOrigin, .waitingForDeviceSource, .sourceMatched,
            .exactUploadRequired, .exactUploading, .probing, .awaitingCredits,
            .reserved, .chunking, .transcribing, .stitching, .detectingAds,
            .resultReady, .delivered, .acknowledged, .cancelling, .cancelled,
            .failed,
        ]
        return Dictionary(uniqueKeysWithValues: cases.map { ($0.wireValue, $0) })
    }()
}

extension OpenCastRemoteTranscriptionJobState: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
