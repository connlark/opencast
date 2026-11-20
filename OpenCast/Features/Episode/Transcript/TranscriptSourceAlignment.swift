import Foundation

/// Trust is proven against the live player item, never episode metadata: a dynamic enclosure
/// URL serves byte-different assemblies. Durations are not compared: a DAI-stitched MP3's stale
/// Xing frame count makes them disagree by seconds on the identical file.
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
