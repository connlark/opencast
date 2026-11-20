import Foundation
import OpenCastTranscription
import SwiftData

struct TrustedCompletedDownload {
    let record: EpisodeDownloadRecord
    let fileURL: URL
    let identity: OpenCastRemoteTranscriptionSourceIdentity
    /// Set only when this resolution hashed an unhashed download to adopt its identity.
    let measuredIdentity: EpisodeTranscriptionSourceIdentity?

    /// A missing or wrong-size file is marked missing and downloaded again once; a second such
    /// failure throws `fileMissing`. Any other read failure, the hash's included, is thrown as
    /// it is: it says nothing about the bytes.
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
        // Hashing a drifted file again cannot vouch for a hashed record: those are not the bytes
        // it recorded. The stamp is taken before hashing, so a download replaced mid-hash does
        // not adopt the hash of the bytes it replaced.
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

    /// A missing file answers false; any other failure to read its attributes throws.
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
