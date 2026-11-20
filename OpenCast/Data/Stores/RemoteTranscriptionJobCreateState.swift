/// `createAttempted` without a `jobID` is a live recovery state: only a repeated create with the
/// same client request ID can say whether a paid job exists.
nonisolated enum RemoteTranscriptionJobCreateState: String, Codable, Sendable {
    /// A client request ID is persisted; no create request has been sent.
    case prepared
    /// Written immediately before the create request can leave the process.
    case createAttempted
    /// The create response was persisted together with its `jobID`.
    case attached

    /// For references persisted without this field.
    nonisolated static func inferred(jobID: String?) -> RemoteTranscriptionJobCreateState {
        jobID == nil ? .prepared : .attached
    }
}
