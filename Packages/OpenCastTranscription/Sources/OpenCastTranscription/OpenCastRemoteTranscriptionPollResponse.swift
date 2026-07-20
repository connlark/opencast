/// Response of `jobs/{id}/poll`. Clients wait `pollAfterSeconds` (plus their
/// own jitter) before the next poll; the server owns pacing.
public struct OpenCastRemoteTranscriptionPollResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var job: OpenCastRemoteTranscriptionJobStatus
    public var pollAfterSeconds: Int

    public init(
        schemaVersion: Int,
        job: OpenCastRemoteTranscriptionJobStatus,
        pollAfterSeconds: Int
    ) {
        self.schemaVersion = schemaVersion
        self.job = job
        self.pollAfterSeconds = pollAfterSeconds
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case job
        case pollAfterSeconds = "poll_after_seconds"
    }
}
