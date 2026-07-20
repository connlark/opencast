/// Optional progress detail for states that process chunks.
public struct OpenCastRemoteTranscriptionJobProgress: Codable, Sendable, Equatable {
    public var chunksCompleted: Int?
    public var chunksTotal: Int?
    public var estimatedRemainingSeconds: Int?
    public var estimateStatus: OpenCastRemoteTranscriptionEstimateStatus?

    public init(
        chunksCompleted: Int? = nil,
        chunksTotal: Int? = nil,
        estimatedRemainingSeconds: Int? = nil,
        estimateStatus: OpenCastRemoteTranscriptionEstimateStatus? = nil
    ) {
        self.chunksCompleted = chunksCompleted
        self.chunksTotal = chunksTotal
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.estimateStatus = estimateStatus
    }

    enum CodingKeys: String, CodingKey {
        case chunksCompleted = "chunks_completed"
        case chunksTotal = "chunks_total"
        case estimatedRemainingSeconds = "estimated_remaining_seconds"
        case estimateStatus = "estimate_status"
    }
}
