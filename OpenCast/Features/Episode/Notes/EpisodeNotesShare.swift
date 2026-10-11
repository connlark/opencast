import Foundation

nonisolated struct EpisodeNotesShare: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let directory: URL
    let textURL: URL
    let markdownURL: URL

    @MainActor init(episodeTitle: String, showTitle: String, notes: [EpisodeNoteRecord]) throws {
        title = episodeTitle
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let name = Self.filename(episodeTitle)
        textURL = directory.appending(path: name + ".txt")
        markdownURL = directory.appending(path: name + ".md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try EpisodeNotesExport.text(episodeTitle: episodeTitle, showTitle: showTitle, notes: notes)
                .write(to: textURL, atomically: true, encoding: .utf8)
            try EpisodeNotesExport.markdown(episodeTitle: episodeTitle, showTitle: showTitle, notes: notes)
                .write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            removeFiles()
            throw error
        }
    }

    // Notes imports Markdown headings; other destinations receive a plain text file.
    func file(for activityIdentifier: String?) -> URL {
        activityIdentifier == "com.apple.mobilenotes.SharingExtension" ? markdownURL : textURL
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func filename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 200 else { break }
            name.append(character)
        }
        return name.isEmpty || name == "." || name == ".." ? "Private Notes" : name
    }
}
