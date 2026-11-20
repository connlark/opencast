/// `.trusted` treats a transcript of other bytes as not yet transcribed: its text can never align
/// with the download.
nonisolated enum EpisodeTranscriptionSourceMatch: Equatable, Sendable {
    case any
    /// A nil hash (no trusted download) matches no transcript.
    case trusted(sha256: String?)

    func admits(transcriptSourceSHA256: String) -> Bool {
        switch self {
        case .any:
            true
        case .trusted(let sha256):
            TranscriptSourceAlignment.downloadMatchesTranscript(
                trustedDownloadSHA256: sha256,
                documentSHA256: transcriptSourceSHA256
            )
        }
    }
}
