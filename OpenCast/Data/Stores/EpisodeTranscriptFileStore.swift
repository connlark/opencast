import Foundation
import OpenCastTranscription

struct EpisodeTranscriptFileStore: Sendable {
    nonisolated static let directoryName = "EpisodeTranscripts"

    let baseDirectory: URL
    let beforeDocumentWriteForTesting: (@Sendable (_ relativePath: String) async -> Void)?
    let beforeDocumentReadForTesting: (@Sendable (_ relativePath: String) async -> Void)?

    init(
        baseDirectory: URL = .applicationSupportDirectory,
        beforeDocumentWriteForTesting: (@Sendable (_ relativePath: String) async -> Void)? = nil,
        beforeDocumentReadForTesting: (@Sendable (_ relativePath: String) async -> Void)? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.beforeDocumentWriteForTesting = beforeDocumentWriteForTesting
        self.beforeDocumentReadForTesting = beforeDocumentReadForTesting
    }

    nonisolated var transcriptsDirectory: URL {
        baseDirectory.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    nonisolated func prepareTranscriptsDirectory() throws {
        try LocalBackupExclusion.apply(to: transcriptsDirectory)
    }

    nonisolated func relativePath(episodeID: String, fingerprint: String) -> String {
        "\(Self.directoryName)/\(safeStem(episodeID))/\(safeStem(fingerprint)).json"
    }

    nonisolated func fingerprint(
        sourceFileSHA256: String,
        modelIdentifier: String,
        modelVersion: String,
        modelTreeSHA256: String
    ) -> String {
        let value = [
            sourceFileSHA256,
            modelIdentifier,
            modelVersion,
            modelTreeSHA256
        ].joined(separator: "|")
        return OpenCastSHA256.hash(Data(value.utf8))
    }

    /// Domain-separated and keyed on the serving contract, so a contract change never overwrites a
    /// local or earlier remote transcript file.
    nonisolated func remoteFingerprint(
        sourceFileSHA256: String,
        provider: String,
        providerModelIdentifier: String,
        servingContractVersion: String,
        pipelineVersion: String
    ) -> String {
        let value = [
            "remote",
            sourceFileSHA256,
            provider,
            providerModelIdentifier,
            servingContractVersion,
            pipelineVersion
        ].joined(separator: "|")
        return OpenCastSHA256.hash(Data(value.utf8))
    }

    nonisolated func fileURL(relativePath: String) -> URL {
        baseDirectory.appending(path: relativePath)
    }

    nonisolated func documentExists(relativePath: String?) -> Bool {
        guard let relativePath else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL(relativePath: relativePath).path)
    }

    nonisolated func read(relativePath: String) throws -> EpisodeTranscriptDocument {
        let data = try Data(contentsOf: fileURL(relativePath: relativePath))
        return try JSONDecoder.openCastTranscriptDecoder.decode(EpisodeTranscriptDocument.self, from: data)
    }

    @concurrent
    func readOffCaller(relativePath: String) async throws -> EpisodeTranscriptDocument {
        await beforeDocumentReadForTesting?(relativePath)
        return try read(relativePath: relativePath)
    }

    /// Staged beside its place so a write that returns after its run ended, or after a local run
    /// took the episode, can be discarded without leaving a document behind.
    @concurrent
    func stageOffCaller(
        _ document: EpisodeTranscriptDocument,
        relativePath: String,
        ignoringCancellation: Bool = false
    ) async throws -> URL {
        if !ignoringCancellation {
            try Task.checkCancellation()
        }
        await beforeDocumentWriteForTesting?(relativePath)
        let url = fileURL(relativePath: relativePath)
        let stagedURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).staged")
        try write(document, to: stagedURL)
        return stagedURL
    }

    nonisolated func placeStagedDocument(at stagedURL: URL, relativePath: String) throws {
        guard rename(stagedURL.path, fileURL(relativePath: relativePath).path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            discardStagedDocument(at: stagedURL)
            throw error
        }
    }

    nonisolated func discardStagedDocument(at stagedURL: URL) {
        try? removeItemIfPresent(at: stagedURL)
    }

    nonisolated func write(_ document: EpisodeTranscriptDocument, relativePath: String) throws {
        try write(document, to: fileURL(relativePath: relativePath))
    }

    private nonisolated func write(_ document: EpisodeTranscriptDocument, to url: URL) throws {
        try prepareTranscriptsDirectory()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.openCastTranscriptEncoder.encode(document)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated func delete(relativePath: String?) throws {
        guard let relativePath else {
            return
        }
        try removeItemIfPresent(at: fileURL(relativePath: relativePath))
    }

    nonisolated func deleteTranscripts(forEpisodeID episodeID: String) throws {
        try removeItemIfPresent(at: transcriptsDirectory.appending(path: safeStem(episodeID)))
    }

    nonisolated func deleteTranscripts(forEpisodeID episodeID: String, keeping keptRelativePath: String) throws {
        let keptName = fileURL(relativePath: keptRelativePath).lastPathComponent
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: transcriptsDirectory.appending(path: safeStem(episodeID), directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        for fileURL in fileURLs where fileURL.lastPathComponent != keptName {
            try removeItemIfPresent(at: fileURL)
        }
    }

    nonisolated func migrateTranscripts(fromEpisodeID oldEpisodeID: String, to newEpisodeID: String) throws {
        try migratePerEpisodeDirectory(
            from: transcriptsDirectory.appending(path: safeStem(oldEpisodeID), directoryHint: .isDirectory),
            to: transcriptsDirectory.appending(path: safeStem(newEpisodeID), directoryHint: .isDirectory)
        )
    }

    private nonisolated func migratePerEpisodeDirectory(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        for fileURL in try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil) {
            let targetURL = destinationURL.appending(path: fileURL.lastPathComponent)
            if !fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.moveItem(at: fileURL, to: targetURL)
            }
        }
        try removeItemIfPresent(at: sourceURL)
    }

    nonisolated func deleteAllTranscripts() throws {
        try removeItemIfPresent(at: transcriptsDirectory)
    }

    nonisolated func safeStem(_ rawValue: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var value = ""
        for scalar in rawValue.unicodeScalars {
            if allowedScalars.contains(scalar) {
                value.unicodeScalars.append(scalar)
            } else {
                value.append("-")
            }
        }

        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String((trimmed.isEmpty ? "transcript" : trimmed).prefix(96))
    }

    private nonisolated func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            throw error
        }
    }
}

private extension JSONEncoder {
    nonisolated static var openCastTranscriptEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var openCastTranscriptDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
