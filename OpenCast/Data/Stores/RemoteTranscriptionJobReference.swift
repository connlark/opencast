import Foundation

/// Device-local reference to a server job, persisted for relaunch recovery
/// and duplicate-submit prevention. The server maps a repeated
/// `(account, clientRequestID)` to the same job, so the reference is the
/// client half of that idempotency contract.
///
/// The recovery fields are additive: JSON written before they existed decodes
/// with `createState` inferred from `jobID`, no exit, no cancel intent and a
/// local completion owner.
nonisolated struct RemoteTranscriptionJobReference: Codable, Sendable, Equatable {
    /// How long a reference stays eligible for re-attach, matching the
    /// server's unacknowledged-result retention.
    static let recoveryWindow: TimeInterval = 7 * 24 * 60 * 60

    var episodeID: String
    var clientRequestID: String
    var jobID: String?
    var createdAt: Date
    /// Absent on references persisted before cloud detect passes existed;
    /// those were all plain transcription jobs.
    var purpose: RemoteTranscriptionJobPurpose?
    var createState: RemoteTranscriptionJobCreateState
    var lastExit: RemoteTranscriptionJobExit?
    /// Persisted before the local task is cancelled. While set, automatic
    /// re-attach is suppressed until the same reference has resolved its
    /// user-authorized cancellation.
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

    /// True while the reference may still resolve to a live or retained
    /// server result; housekeeping never drops a younger reference merely
    /// because `jobID` is absent.
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
