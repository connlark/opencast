/// Shared media request profile for episode audio: exact bytes, no content
/// negotiation, and a stable, URL-free User-Agent the transcription backend
/// mirrors so server and device fetch the same representation whenever the
/// origin allows it. Remote transcription jobs declare `version`, so the
/// backend fetches with this profile's User-Agent; app versions that predate
/// the declaration keep the legacy one there. Matching headers are never proof
/// of matching bytes — only the hash is.
nonisolated enum OpenCastMediaRequestProfile {
    static let version = 2
    static let acceptEncoding = "identity"
    static let userAgent = "OpenCast-Media/2"
}
