/// Attached means the trusted download holds the bytes the transcript was made from. It is not
/// playback verification, which also needs the live player item to be that file.
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
