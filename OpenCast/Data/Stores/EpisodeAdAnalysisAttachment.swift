/// Whether an episode's ad analysis still describes audio the device holds:
/// attached while the episode's trusted completed download has the bytes
/// its transcript was made from, detached otherwise. A detached analysis can
/// still be current (its transcript fingerprint matches), but its skip
/// zones can never verify against playback until a pass transcribes the
/// download again. Attachment is not playback verification, which also
/// needs the live player item to be that file.
nonisolated enum EpisodeAdAnalysisAttachment: Equatable, Sendable {
    case attached
    case detached

    static func resolve(
        transcriptSourceSHA256: String,
        trustedDownloadSHA256: String?
    ) -> Self {
        TranscriptSourceAlignment.downloadMatchesTranscript(
            trustedDownloadSHA256: trustedDownloadSHA256,
            documentSHA256: transcriptSourceSHA256
        ) ? .attached : .detached
    }
}
