import Foundation

/// The file handed to the activity sheet. When a temporary directory is set,
/// the URL is a hard link with a readable name and only that directory is
/// removed after sharing; otherwise the URL is the original download and
/// cleanup touches nothing.
nonisolated struct EpisodeDiagnosticsShareFile: Sendable, Equatable, Identifiable {
    var url: URL
    var temporaryDirectoryURL: URL?

    var id: String { url.absoluteString }
}

nonisolated enum EpisodeDiagnosticsShareFilePreparer {
    /// Hard-links the download under a sanitized podcast/episode name so the
    /// share carries a meaningful filename without copying the audio. A
    /// failed link (foreign volume, permissions) falls back to sharing the
    /// original file directly.
    static func prepare(source: URL, podcastTitle: String, episodeTitle: String) -> EpisodeDiagnosticsShareFile {
        let fileName = sanitizedFileName(
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            fileExtension: source.pathExtension.isEmpty ? "audio" : source.pathExtension
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EpisodeDiagnosticsShare-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let linkURL = directory.appending(path: fileName)
            try FileManager.default.linkItem(at: source, to: linkURL)
            return EpisodeDiagnosticsShareFile(url: linkURL, temporaryDirectoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return EpisodeDiagnosticsShareFile(url: source, temporaryDirectoryURL: nil)
        }
    }

    static func cleanUp(_ file: EpisodeDiagnosticsShareFile) {
        guard let temporaryDirectoryURL = file.temporaryDirectoryURL else {
            return
        }
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    static func sanitizedFileName(
        podcastTitle: String,
        episodeTitle: String,
        fileExtension: String
    ) -> String {
        let stem = [podcastTitle, episodeTitle]
            .map(sanitizedComponent)
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return "\(stem.isEmpty ? "Episode" : stem).\(fileExtension)"
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = value.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
        return String(String(cleaned).prefix(80))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
