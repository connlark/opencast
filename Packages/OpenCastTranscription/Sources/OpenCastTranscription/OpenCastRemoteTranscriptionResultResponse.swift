/// Response of `jobs/{id}/result`. Served with `Cache-Control: no-store`;
/// the result object is deleted on acknowledgement.
public struct OpenCastRemoteTranscriptionResultResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var result: OpenCastRemoteTranscriptionResult

    public init(schemaVersion: Int, result: OpenCastRemoteTranscriptionResult) {
        self.schemaVersion = schemaVersion
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case result
    }
}
