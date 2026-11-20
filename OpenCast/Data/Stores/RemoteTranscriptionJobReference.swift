import Foundation

/// The client half of an idempotency contract: the server maps a repeated
/// `(account, clientRequestID)` to the same job.
nonisolated struct RemoteTranscriptionJobReference: Codable, Sendable, Equatable {
    /// Matches the server's unacknowledged-result retention.
    static let recoveryWindow: TimeInterval = 7 * 24 * 60 * 60

    var episodeID: String
    var clientRequestID: String
    var jobID: String?
    var createdAt: Date
    /// nil on older references, which were all plain transcription jobs.
    var purpose: RemoteTranscriptionJobPurpose?
    var createState: RemoteTranscriptionJobCreateState
    var lastExit: RemoteTranscriptionJobExit?
    /// Persisted before the local task is cancelled; while set, automatic re-attach waits until
    /// this reference's cancel resolves.
    var userCancelRequestedAt: Date?
    var completionDeliveryOwner: JobCompletionDeliveryOwner

    init(
        episodeID: String,
        clientRequestID: String,
        jobID: String?,
        createdAt: Date,
        purpose: RemoteTranscriptionJobPurpose?,
        createState: RemoteTranscriptionJobCreateState? = nil,
        lastExit: RemoteTranscriptionJobExit? = nil,
        userCancelRequestedAt: Date? = nil,
        completionDeliveryOwner: JobCompletionDeliveryOwner = .local
    ) {
        self.episodeID = episodeID
        self.clientRequestID = clientRequestID
        self.jobID = jobID
        self.createdAt = createdAt
        self.purpose = purpose
        self.createState = createState ?? .inferred(jobID: jobID)
        self.lastExit = lastExit
        self.userCancelRequestedAt = userCancelRequestedAt
        self.completionDeliveryOwner = completionDeliveryOwner
    }

    var resolvedPurpose: RemoteTranscriptionJobPurpose {
        purpose ?? .transcription
    }

    /// Age alone decides: a missing `jobID` never ends a younger reference's recovery.
    func isWithinRecoveryWindow(asOf now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) < Self.recoveryWindow
    }

    private enum CodingKeys: String, CodingKey {
        case episodeID
        case clientRequestID
        case jobID
        case createdAt
        case purpose
        case createState
        case lastExit
        case userCancelRequestedAt
        case completionDeliveryOwner
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        self.init(
            episodeID: try container.decode(String.self, forKey: .episodeID),
            clientRequestID: try container.decode(String.self, forKey: .clientRequestID),
            jobID: jobID,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            purpose: try container.decodeIfPresent(RemoteTranscriptionJobPurpose.self, forKey: .purpose),
            createState: try container.decodeIfPresent(RemoteTranscriptionJobCreateState.self, forKey: .createState),
            lastExit: try container.decodeIfPresent(RemoteTranscriptionJobExit.self, forKey: .lastExit),
            userCancelRequestedAt: try container.decodeIfPresent(Date.self, forKey: .userCancelRequestedAt),
            completionDeliveryOwner: try container.decodeIfPresent(
                JobCompletionDeliveryOwner.self,
                forKey: .completionDeliveryOwner
            ) ?? .local
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(episodeID, forKey: .episodeID)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encodeIfPresent(jobID, forKey: .jobID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encode(createState, forKey: .createState)
        try container.encodeIfPresent(lastExit, forKey: .lastExit)
        try container.encodeIfPresent(userCancelRequestedAt, forKey: .userCancelRequestedAt)
        try container.encode(completionDeliveryOwner, forKey: .completionDeliveryOwner)
    }
}
