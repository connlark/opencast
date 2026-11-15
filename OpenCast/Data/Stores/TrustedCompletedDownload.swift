import Foundation
import OpenCastTranscription
import SwiftData

/// A completed download whose bytes are trusted
/// (`DownloadStore.completedSourceIdentity`): the audio an ad-free pass
/// transcribes and a remote job reports and uploads, so the transcript either
/// one makes attaches to the download it came from (D7).
struct TrustedCompletedDownload {
    let record: EpisodeDownloadRecord
    let fileURL: URL
    let identity: OpenCastRemoteTranscriptionSourceIdentity
    /// The file as this resolution measured it, when it hashed an unhashed
    /// download to adopt its identity; nil when the record was already
    /// trusted.
    let measuredIdentity: EpisodeTranscriptionSourceIdentity?

    /// Ensures the episode's completed download and makes it trusted. An
    /// unhashed record whose file has its recorded size adopts the hash of
    /// that file. A file that is gone, or whose size disagrees with the
    /// record, marks the record missing and downloads again, once; a second
    /// such failure throws `CompletedDownloadError.fileMissing`. Any other
    /// failure to read the file, the hash's included, is thrown as it is:
    /// it says nothing about the bytes. `measure` hashes the file; a test
    /// substitutes it to act while the hash runs.
    static func ensure(
        for episode: EpisodeListItemSnapshot,
        downloads: DownloadStore,
        modelContext: ModelContext,
        onWaitStarted: () throws -> Void,
        measure: (URL) async throws -> EpisodeTranscriptionSourceIdentity = {
            try await EpisodeTranscriptionSourceIdentity.load(from: $0)
        }
    ) async throws -> TrustedCompletedDownload {
        var didRetry = false
        while true {
            do {
                let record = try await downloads.ensureCompletedDownload(
                    for: episode,
                    modelContext: modelContext,
                    onWaitStarted: onWaitStarted
                )
                if let trusted = try await trust(
                    record,
                    episodeID: episode.episodeID,
                    downloads: downloads,
                    modelContext: modelContext,
                    measure: measure
                ) {
                    return trusted
                }
            } catch DownloadStore.CompletedDownloadError.fileMissing where !didRetry {
                didRetry = true
                continue
            }

            if let record = downloads.record(for: episode.episodeID), record.state == .completed {
                try? downloads.markDownloadedFileMissing(record, modelContext: modelContext)
            }
            guard !didRetry else {
                throw DownloadStore.CompletedDownloadError.fileMissing
            }
            didRetry = true
        }
    }

    private static func trust(
        _ record: EpisodeDownloadRecord,
        episodeID: String,
        downloads: DownloadStore,
        modelContext: ModelContext,
        measure: (URL) async throws -> EpisodeTranscriptionSourceIdentity
    ) async throws -> TrustedCompletedDownload? {
        guard let fileURL = downloads.localFileURL(for: record) else {
            return nil
        }
        if let identity = downloads.completedSourceIdentity(for: episodeID) {
            return TrustedCompletedDownload(
                record: record,
                fileURL: fileURL,
                identity: identity,
                measuredIdentity: nil
            )
        }
        // A hashed record whose file drifted cannot be vouched for by
        // hashing it again: those bytes are not the ones it recorded. The
        // file is stamped before it is hashed, so a download replaced while
        // the hash runs does not adopt the hash of the bytes it replaced.
        guard try hasRecordedSize(fileURL, bytesReceived: record.bytesReceived),
              record.sourceFileSHA256.isEmpty,
              let measuredFile = downloads.completedFileStamp(of: record)
        else {
            return nil
        }

        let measured: EpisodeTranscriptionSourceIdentity
        do {
            measured = try await measure(fileURL)
        } catch {
            try Task.checkCancellation()
            // Only a file that went away or changed size while it was hashed
            // is untrusted; any other failure is the hash's own.
            guard try hasRecordedSize(fileURL, bytesReceived: record.bytesReceived) else {
                return nil
            }
            throw error
        }
        try Task.checkCancellation()
        try downloads.adoptSourceHash(
            measured.sha256,
            byteCount: measured.byteCount,
            measuredFile: measuredFile,
            for: episodeID,
            modelContext: modelContext
        )
        guard let current = downloads.record(for: episodeID),
              let currentFileURL = downloads.localFileURL(for: current),
              let identity = downloads.completedSourceIdentity(for: episodeID)
        else {
            return nil
        }
        return TrustedCompletedDownload(
            record: current,
            fileURL: currentFileURL,
            identity: identity,
            measuredIdentity: identity.sha256 == measured.sha256 ? measured : nil
        )
    }

    /// Whether the download's file is there, a regular file of the size its
    /// record holds. A file that is gone answers false; any other failure to
    /// read its attributes is thrown.
    private static func hasRecordedSize(_ fileURL: URL, bytesReceived: Int64) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return false
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return (attributes[.size] as? Int64) == bytesReceived
    }
}
