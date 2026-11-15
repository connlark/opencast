/// What a completed transcript must have been made from for
/// `EpisodeTranscriptionStore.jobState` to report it `.completed`. Display
/// surfaces ask `.any`: a transcript exists, whatever audio it describes. The
/// ad-free pass asks `.trusted` with the hash of the download it holds, so a
/// transcript of other bytes reads as not yet transcribed and the pass
/// transcribes the download again instead of reusing text that can never
/// align with it.
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
