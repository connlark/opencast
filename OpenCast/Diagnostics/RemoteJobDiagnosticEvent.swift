import Foundation
import OpenCastTranscription

/// No free-form string: every field is a closed vocabulary value, an opaque identifier, a
/// count or a duration.
nonisolated struct RemoteJobDiagnosticEvent: Codable, Sendable, Equatable {
    enum Component: String, Codable, Sendable, CaseIterable {
        case runner
        case jobStore
        case plainCoordinator
        case passQueue
        case backgroundSession
        case reattach
        case completionDelivery
        case uploadSession
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case runStarted
        case runEnded
        case createAttempted
        case createAttached
        case createUncertain
        case legStarted
        case legRetried
        case legFailed
        case legSucceeded
        case pollObserved
        case parked
        case referenceCleared
        case userCancelRequested
        case cancelAttempted
        case cancelUncertain
        case imported
        case acknowledged
        case acknowledgedWithoutLocalImport
        case reattachStarted
        case reattachSkipped
        case housekeepingExpired
        case sessionArmed
        case sessionLaunched
        case sessionExpired
        case sessionCompleted
        case sessionForegroundOnly
        case notificationScheduled
        case notificationSuppressed
    }

    enum Leg: String, Codable, Sendable, CaseIterable {
        case bootstrap
        case create
        case source
        case poll
        case uploadStart
        case uploadParts
        case uploadComplete
        case result
        case ack
        case cancel
        case redeem
        case download
        case identity
        case importTranscript
    }

    /// `skipped…` values give a `reattachSkipped` reason, and the reference is retained;
    /// `suppressed…` values and `deliveryFailed` give a `notificationSuppressed` reason and say
    /// nothing about the reference.
    enum Disposition: String, Codable, Sendable, CaseIterable {
        case retained
        case attached
        case parked
        case cleared
        case cancelIntentPersisted
        case cancelAttempted
        case expired
        case skippedCancelIntent
        case skippedNotCreated
        case skippedUnresolvedEpisode
        case skippedActiveRequest
        case skippedCompletedTranscript
        case suppressedRemoteOwner
        case suppressedSceneActive
        case suppressedUnauthorized
        case suppressedSilentOutcome
        case deliveryFailed
    }

    let timestamp: Date
    let component: Component
    let kind: Kind
    let episodeID: String?
    let jobID: String?
    let clientRequestID: String?
    let purpose: RemoteTranscriptionJobPurpose?
    let leg: Leg?
    let attempt: Int?
    let elapsedMilliseconds: Int?
    let httpStatus: Int?
    /// An unknown state encodes as `unknown`, never as the server's raw string.
    let serverState: OpenCastRemoteTranscriptionJobState?
    let error: RemoteJobDiagnosticError?
    let disposition: Disposition?

    init(
        timestamp: Date = .now,
        component: Component,
        kind: Kind,
        episodeID: String? = nil,
        jobID: String? = nil,
        clientRequestID: String? = nil,
        purpose: RemoteTranscriptionJobPurpose? = nil,
        leg: Leg? = nil,
        attempt: Int? = nil,
        elapsedMilliseconds: Int? = nil,
        httpStatus: Int? = nil,
        serverState: OpenCastRemoteTranscriptionJobState? = nil,
        error: RemoteJobDiagnosticError? = nil,
        disposition: Disposition? = nil
    ) {
        self.timestamp = timestamp
        self.component = component
        self.kind = kind
        self.episodeID = episodeID
        self.jobID = jobID
        self.clientRequestID = clientRequestID
        self.purpose = purpose
        self.leg = leg
        self.attempt = attempt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.httpStatus = httpStatus
        self.serverState = serverState
        self.error = error
        self.disposition = disposition
    }

    /// A new field must be listed here, or the log drops every event that carries it.
    static let allowedFieldNames: Set<String> = [
        "timestamp", "component", "kind", "episodeID", "jobID", "clientRequestID",
        "purpose", "leg", "attempt", "elapsedMilliseconds", "httpStatus",
        "serverState", "error", "disposition",
    ]

    static func encodedServerState(_ state: OpenCastRemoteTranscriptionJobState) -> String {
        if case .unknown = state {
            return "unknown"
        }
        return state.wireValue
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, component, kind, episodeID, jobID, clientRequestID, purpose, leg
        case attempt, elapsedMilliseconds, httpStatus, serverState, error, disposition
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            component: try container.decode(Component.self, forKey: .component),
            kind: try container.decode(Kind.self, forKey: .kind),
            episodeID: try container.decodeIfPresent(String.self, forKey: .episodeID),
            jobID: try container.decodeIfPresent(String.self, forKey: .jobID),
            clientRequestID: try container.decodeIfPresent(String.self, forKey: .clientRequestID),
            purpose: try container.decodeIfPresent(RemoteTranscriptionJobPurpose.self, forKey: .purpose),
            leg: try container.decodeIfPresent(Leg.self, forKey: .leg),
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt),
            elapsedMilliseconds: try container.decodeIfPresent(Int.self, forKey: .elapsedMilliseconds),
            httpStatus: try container.decodeIfPresent(Int.self, forKey: .httpStatus),
            serverState: try container.decodeIfPresent(String.self, forKey: .serverState)
                .map(OpenCastRemoteTranscriptionJobState.init(wireValue:)),
            error: try container.decodeIfPresent(RemoteJobDiagnosticError.self, forKey: .error),
            disposition: try container.decodeIfPresent(Disposition.self, forKey: .disposition)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(component, forKey: .component)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(episodeID, forKey: .episodeID)
        try container.encodeIfPresent(jobID, forKey: .jobID)
        try container.encodeIfPresent(clientRequestID, forKey: .clientRequestID)
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encodeIfPresent(leg, forKey: .leg)
        try container.encodeIfPresent(attempt, forKey: .attempt)
        try container.encodeIfPresent(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        try container.encodeIfPresent(httpStatus, forKey: .httpStatus)
        try container.encodeIfPresent(serverState.map(Self.encodedServerState), forKey: .serverState)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(disposition, forKey: .disposition)
    }
}

/// Implementations must be safe from any isolation and must not block the caller on file
/// I/O.
nonisolated protocol RemoteJobDiagnosticSink: Sendable {
    func record(_ event: RemoteJobDiagnosticEvent)
}
