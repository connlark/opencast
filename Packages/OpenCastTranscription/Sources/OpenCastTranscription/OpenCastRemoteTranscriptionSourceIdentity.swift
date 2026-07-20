/// Exact identity of an episode audio source as observed by one party.
///
/// The server never reserves credits or calls a model until the device and
/// server identities agree on `sha256` and `byteCount`. Header values are
/// diagnostic only and never substitute for the hash.
public struct OpenCastRemoteTranscriptionSourceIdentity: Codable, Sendable, Equatable {
    public var sha256: String
    public var byteCount: Int64
    public var durationSeconds: Double?
    public var entityTag: String?
    public var lastModified: String?
    /// SHA-256 of the final (post-redirect) URL string; raw URLs stay off the wire.
    public var finalURLSHA256: String?

    public init(
        sha256: String,
        byteCount: Int64,
        durationSeconds: Double? = nil,
        entityTag: String? = nil,
        lastModified: String? = nil,
        finalURLSHA256: String? = nil
    ) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.finalURLSHA256 = finalURLSHA256
    }

    enum CodingKeys: String, CodingKey {
        case sha256
        case byteCount = "byte_count"
        case durationSeconds = "duration_seconds"
        case entityTag = "entity_tag"
        case lastModified = "last_modified"
        case finalURLSHA256 = "final_url_sha256"
    }
}
