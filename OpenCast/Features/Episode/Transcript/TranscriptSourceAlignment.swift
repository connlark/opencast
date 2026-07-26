import Foundation

/// Verdict on whether follow-along/karaoke may trust the current player item
/// as the exact audio asset the transcript describes. Dynamic enclosure URLs
/// return byte-different assemblies per request, so trust is proven against
/// the live `AVPlayerItem` — never episode metadata: the item must have been
/// created from the completed download whose trusted byte identity matches
/// the transcript's recorded source hash.
///
/// Durations are deliberately not compared. DAI-stitched MP3s often carry a
/// stale Xing frame count, so a precise container walk and the transcriber's
/// decoded PCM legitimately disagree by seconds on the identical file while
/// mid-file times stay aligned (both clocks count from sample zero). The
/// media-time-origin invariant is enforced structurally instead: local-file
/// player items load with `AVURLAssetPreferPreciseDurationAndTiming`, so the
/// player never maps time through an estimated (possibly stale) TOC.
nonisolated enum TranscriptSourceAlignment: Equatable {
    case verified
    case mismatched(canSwitchToTranscribedCopy: Bool)

    static func resolve(
        documentSHA256: String,
        trustedDownloadSHA256: String?,
        downloadFileURL: URL?,
        playerItemURL: URL?
    ) -> Self {
        let canSwitch = downloadMatchesTranscript(
            trustedDownloadSHA256: trustedDownloadSHA256,
            documentSHA256: documentSHA256
        )
        guard canSwitch,
              let downloadFileURL,
              let playerItemURL,
              playerItemURL.isFileURL,
              playerItemURL.standardizedFileURL == downloadFileURL.standardizedFileURL
        else {
            return .mismatched(canSwitchToTranscribedCopy: canSwitch)
        }
        return .verified
    }

    /// Whether the completed download's trusted byte identity proves it is
    /// the audio the transcript was generated from. Engine-independent: the
    /// document hash comes from local Whisper, Apple Speech, or the remote
    /// pipeline alike.
    static func downloadMatchesTranscript(
        trustedDownloadSHA256: String?,
        documentSHA256: String
    ) -> Bool {
        guard !documentSHA256.isEmpty,
              let trustedDownloadSHA256,
              !trustedDownloadSHA256.isEmpty
        else {
            return false
        }
        return trustedDownloadSHA256 == documentSHA256
    }
}
