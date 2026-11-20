/// RemoteTranscriptionWorker mirrors these values (`MEDIA_USER_AGENT`) so server and device fetch
/// the same representation. Matching headers never prove matching bytes; only the hash does.
nonisolated enum OpenCastMediaRequestProfile {
    static let version = 2
    static let acceptEncoding = "identity"
    static let userAgent = "OpenCast-Media/2"
}
