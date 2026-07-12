import Foundation
import OpenCastTranscription

struct EpisodeTranscriptFileStore: Sendable {
    nonisolated static let directoryName = "EpisodeTranscripts"

    let baseDirectory: URL

    init(baseDirectory: URL = .applicationSupportDirectory) {
        self.baseDirectory = baseDirectory
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
        try read(relativePath: relativePath)
    }

    nonisolated func write(_ document: EpisodeTranscriptDocument, relativePath: String) throws {
        try prepareTranscriptsDirectory()
        let url = fileURL(relativePath: relativePath)
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
