import Foundation

extension OpenCastAppModel {
    /// For every decision that starts or skips work and every surface that enables an action: one
    /// file stat, so a file that went missing or drifted mid-session reads detached at once.
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

    /// Passive display only: no I/O, so a file that went missing or drifted this session still
    /// reads attached here until the next launch.
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
