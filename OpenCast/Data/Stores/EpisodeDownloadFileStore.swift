import Foundation

struct EpisodeDownloadFileStore: Sendable {
    nonisolated static let directoryName = "EpisodeDownloads"

    let baseDirectory: URL

    init(baseDirectory: URL = .applicationSupportDirectory) {
        self.baseDirectory = baseDirectory
    }

    nonisolated var downloadsDirectory: URL {
        baseDirectory.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    nonisolated func relativePath(episodeID: String, sourceAudioURL: URL) -> String {
        let extensionName = safeExtension(from: sourceAudioURL)
        return "\(Self.directoryName)/\(safeStem(episodeID: episodeID)).\(extensionName)"
    }

    nonisolated func fileURL(relativePath: String) -> URL {
        baseDirectory.appending(path: relativePath)
    }

    nonisolated func temporaryFileURL(episodeID: String, token: String) -> URL {
        downloadsDirectory.appending(path: "\(safeStem(episodeID: episodeID))-\(token).partial")
    }

    nonisolated func pausedPartialFileURL(episodeID: String) -> URL {
        downloadsDirectory.appending(path: "\(safeStem(episodeID: episodeID)).partial")
    }

    nonisolated func prepareDownloadsDirectory() throws {
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        try LocalBackupExclusion.apply(to: downloadsDirectory)
    }

    nonisolated func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(relativePath: relativePath).path)
    }

    nonisolated func fileSize(relativePath: String) throws -> Int64 {
        try fileSize(at: fileURL(relativePath: relativePath))
    }

    nonisolated func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    @discardableResult
    nonisolated func moveCompletedDownload(from temporaryURL: URL, relativePath: String) throws -> URL {
        try prepareDownloadsDirectory()
        let destinationURL = fileURL(relativePath: relativePath)
        try removeItemIfPresent(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    @discardableResult
    nonisolated func promoteTemporaryFileToPausedPartial(
        _ temporaryURL: URL,
        episodeID: String
    ) throws -> Int64 {
        try prepareDownloadsDirectory()
        let pausedURL = pausedPartialFileURL(episodeID: episodeID)
        if temporaryURL.standardizedFileURL != pausedURL.standardizedFileURL {
            try removeItemIfPresent(at: pausedURL)
            try FileManager.default.moveItem(at: temporaryURL, to: pausedURL)
        }
        return try fileSize(at: pausedURL)
    }

    @discardableResult
    nonisolated func movePausedPartialToTemporaryFile(
        episodeID: String,
        token: String
    ) throws -> URL {
        try prepareDownloadsDirectory()
        let temporaryURL = temporaryFileURL(episodeID: episodeID, token: token)
        try removeItemIfPresent(at: temporaryURL)
        try FileManager.default.moveItem(
            at: pausedPartialFileURL(episodeID: episodeID),
            to: temporaryURL
        )
        return temporaryURL
    }

    nonisolated func adoptNewestTemporaryPartial(episodeID: String) throws -> Int64? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: downloadsDirectory.path) else {
            return nil
        }

        let stem = safeStem(episodeID: episodeID)
        let prefix = "\(stem)-"
        let candidates = try fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { fileURL in
            let name = fileURL.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".partial") else {
                return false
            }
            return name.dropFirst(prefix.count).dropLast(".partial".count).isEmpty == false
        }

        let datedCandidates: [(url: URL, modifiedAt: Date)] = try candidates.compactMap { fileURL in
            let values = try fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true else {
                return nil
            }
            return (url: fileURL, modifiedAt: values.contentModificationDate ?? .distantPast)
        }
        guard let newest = datedCandidates.max(by: { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.modifiedAt < rhs.modifiedAt
        }) else {
            return nil
        }

        let fileSize = try promoteTemporaryFileToPausedPartial(newest.url, episodeID: episodeID)
        try removeTemporaryFiles(episodeID: episodeID)
        return fileSize
    }

    nonisolated func removePausedPartial(episodeID: String) throws {
        try removeItemIfPresent(at: pausedPartialFileURL(episodeID: episodeID))
    }

    nonisolated func removeFile(relativePath: String?) throws {
        guard let relativePath else {
            return
        }

        try removeItemIfPresent(at: fileURL(relativePath: relativePath))
    }

    nonisolated func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            throw error
        }
    }

    nonisolated func removeTemporaryFiles(episodeID: String) throws {
        let directoryURL = downloadsDirectory
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        let stem = safeStem(episodeID: episodeID)
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix("\(stem)-")
            && fileURL.lastPathComponent.hasSuffix(".partial") {
            try removeItemIfPresent(at: fileURL)
        }
    }

    nonisolated func removeAllDownloads() throws {
        try removeItemIfPresent(at: downloadsDirectory)
    }

    nonisolated func safeStem(episodeID: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var value = ""
        for scalar in episodeID.unicodeScalars {
            if allowedScalars.contains(scalar) {
                value.unicodeScalars.append(scalar)
            } else {
                value.append("-")
            }
        }

        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let stem = trimmed.isEmpty ? "episode" : trimmed
        return String(stem.prefix(96))
    }

    private nonisolated func safeExtension(from sourceAudioURL: URL) -> String {
        let extensionName = sourceAudioURL.pathExtension.lowercased()
        let allowedScalars = CharacterSet.alphanumerics
        var value = ""
        for scalar in extensionName.unicodeScalars where allowedScalars.contains(scalar) {
            value.unicodeScalars.append(scalar)
        }

        return value.isEmpty || value == "partial" ? "audio" : String(value.prefix(12))
    }
}
