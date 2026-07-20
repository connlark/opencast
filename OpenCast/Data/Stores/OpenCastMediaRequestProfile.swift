/// Shared media request profile for episode audio: exact bytes, no content
/// negotiation, and a stable User-Agent the transcription backend mirrors so
/// server and device fetch the same representation whenever the origin allows
/// it. Matching headers are never proof of matching bytes — only the hash is.
nonisolated enum OpenCastMediaRequestProfile {
    static let acceptEncoding = "identity"
    static let userAgent = "OpenCast-Media/1 (+https://opencast.mobile)"
}
