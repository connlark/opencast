/// Machine-readable failure attached to a job status.
public struct OpenCastRemoteTranscriptionJobError: Codable, Sendable, Equatable {
    public var code: OpenCastRemoteTranscriptionErrorCode
    public var message: String?

    public init(code: OpenCastRemoteTranscriptionErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}
