import Foundation
import OpenCastTranscription

struct EpisodeAdAnalysisFileStore: Sendable {
    nonisolated static let directoryName = "EpisodeAdAnalyses"

    let baseDirectory: URL

    nonisolated init(baseDirectory: URL = .applicationSupportDirectory) {
        self.baseDirectory = baseDirectory
    }

    nonisolated var analysesDirectory: URL {
        baseDirectory.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    nonisolated func prepareAnalysesDirectory() throws {
        try LocalBackupExclusion.apply(to: analysesDirectory)
    }

    nonisolated func relativePath(episodeID: String, transcriptFingerprint: String) -> String {
        "\(Self.directoryName)/\(safeStem(episodeID))/\(safeStem(transcriptFingerprint)).json"
    }

    nonisolated func transcriptFingerprint(for document: EpisodeTranscriptDocument) -> String {
        transcriptFingerprint(
            for: document,
            segments: OpenCastTranscriptSegmentNormalizer.normalized(document.segments)
        )
    }

    nonisolated func transcriptFingerprint(
        for document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment]
    ) -> String {
        var value = [
            document.episodeID,
            document.podcastID,
            document.sourceFileSHA256,
            document.modelIdentifier,
            document.modelVersion,
            document.modelTreeSHA256,
            document.updatedAt.ISO8601Format(),
            "\(segments.count)"
        ].joined(separator: "|")

        for segment in segments {
            value += "|\(segment.id):\(segment.start):\(segment.end):\(segment.text)"
        }
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

    nonisolated func read(relativePath: String) throws -> EpisodeAdAnalysisDocument {
        let data = try Data(contentsOf: fileURL(relativePath: relativePath))
        return try EpisodeAdAnalysisJSONCoding.decoder().decode(EpisodeAdAnalysisDocument.self, from: data)
    }

    @concurrent
    func readOffCaller(relativePath: String) async throws -> EpisodeAdAnalysisDocument {
        try read(relativePath: relativePath)
    }

    nonisolated func write(_ document: EpisodeAdAnalysisDocument, relativePath: String) throws {
        try prepareAnalysesDirectory()
        let url = fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.openCastAdAnalysisEncoder.encode(document)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated func delete(relativePath: String?) throws {
        guard let relativePath else {
            return
        }
        try removeItemIfPresent(at: fileURL(relativePath: relativePath))
    }

    nonisolated func deleteAnalyses(forEpisodeID episodeID: String) throws {
        try removeItemIfPresent(at: analysesDirectory.appending(path: safeStem(episodeID)))
    }

    nonisolated func deleteAllAnalyses() throws {
        try removeItemIfPresent(at: analysesDirectory)
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
        return String((trimmed.isEmpty ? "analysis" : trimmed).prefix(96))
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
    nonisolated static var openCastAdAnalysisEncoder: JSONEncoder {
        EpisodeAdAnalysisJSONCoding.encoder(outputFormatting: [.prettyPrinted, .sortedKeys])
    }
}
