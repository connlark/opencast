import Foundation

extension OpenCastAppModel {
    /// The trusted form, for every decision that starts or skips work and
    /// every surface that enables an action: the download must still be a
    /// completed, hashed file of its recorded size (one file stat), so a
    /// file that went missing or drifted mid-session reads detached at once.
    func isAdAnalysisAttached(for episodeID: String) -> Bool {
        guard let transcriptSourceSHA256 = transcriptions.record(for: episodeID)?.sourceFileSHA256,
              !transcriptSourceSHA256.isEmpty
        else {
            return false
        }
        return EpisodeAdAnalysisAttachment.resolve(
            transcriptSourceSHA256: transcriptSourceSHA256,
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episodeID)?.sha256
        ) == .attached
    }

    /// The display form, for passive display only: the download record's
    /// stored state and hash, no I/O. Launch reconciliation keeps a drifted
    /// or missing file from reading attached here after the next launch;
    /// within a session only the trusted form sees it.
    func isAdAnalysisAttachedByRecord(for episodeID: String) -> Bool {
        let downloadRecord = downloads.record(for: episodeID)
        return EpisodeAdAnalysisAttachment.resolve(
            transcriptSourceSHA256: transcriptions.record(for: episodeID)?.sourceFileSHA256 ?? "",
            trustedDownloadSHA256: downloadRecord?.state == .completed
                ? downloadRecord?.sourceFileSHA256
                : nil
        ) == .attached
    }
}
