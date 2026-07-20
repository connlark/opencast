import Foundation

/// Device-local reference to a server job, persisted for relaunch recovery
/// and duplicate-submit prevention. The server maps a repeated
/// `(account, clientRequestID)` to the same job, so the reference is the
/// client half of that idempotency contract.
nonisolated struct RemoteTranscriptionJobReference: Codable, Sendable, Equatable {
    var episodeID: String
    var clientRequestID: String
    var jobID: String?
    var createdAt: Date
}
