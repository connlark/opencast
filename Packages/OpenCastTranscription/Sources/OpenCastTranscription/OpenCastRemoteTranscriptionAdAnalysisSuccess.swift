/// Payload of a completed chained ad analysis inside the result envelope's
/// `ad_analysis` block.
public struct OpenCastRemoteTranscriptionAdAnalysisSuccess: Codable, Sendable, Equatable {
    public var model: String
    public var policy: String
    public var policyRevision: String?
    public var spans: [OpenCastRemoteTranscriptionAdAnalysisSpan]
    public var warnings: [String]

    public init(
        model: String,
        policy: String,
        spans: [OpenCastRemoteTranscriptionAdAnalysisSpan],
        warnings: [String] = [],
        policyRevision: String? = nil
    ) {
        self.model = model
        self.policy = policy
        self.policyRevision = policyRevision
        self.spans = spans
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case model
        case policy
        case policyRevision = "policy_revision"
        case spans
        case warnings
    }
}
