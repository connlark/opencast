/// Wire schema version for the remote transcription job API.
///
/// Every top-level request/response payload carries `schema_version`. Servers
/// and clients treat a higher version as decodable-if-compatible; unknown
/// enum values are preserved, never dropped.
public enum OpenCastRemoteTranscriptionSchema {
    public static let version = 1
}
