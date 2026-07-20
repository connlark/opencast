/// Snapshot of one job as returned by create/source/poll/ack/cancel routes.
public struct OpenCastRemoteTranscriptionJobStatus: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: OpenCastRemoteTranscriptionJobState
    public var episodeID: String?
    public var progress: OpenCastRemoteTranscriptionJobProgress?
    public var error: OpenCastRemoteTranscriptionJobError?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        jobID: String,
        state: OpenCastRemoteTranscriptionJobState,
        episodeID: String? = nil,
        progress: OpenCastRemoteTranscriptionJobProgress? = nil,
        error: OpenCastRemoteTranscriptionJobError? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.jobID = jobID
        self.state = state
        self.episodeID = episodeID
        self.progress = progress
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case episodeID = "episode_id"
        case progress
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
