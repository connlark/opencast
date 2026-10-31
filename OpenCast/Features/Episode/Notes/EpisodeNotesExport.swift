import Foundation

enum EpisodeNotesExport {
    private static let attribution = "Private Notes from opencast:"

    static func text(episodeTitle: String, showTitle: String, notes: [EpisodeNoteRecord]) -> String {
        ([episodeTitle + "\n" + showTitle, attribution] + noteSections(notes)).joined(separator: "\n\n")
    }

    static func markdown(episodeTitle: String, showTitle: String, notes: [EpisodeNoteRecord]) -> String {
        let title = episodeTitle.components(separatedBy: .newlines).joined(separator: " ")
        let show = showTitle.components(separatedBy: .newlines).joined(separator: " ")
        let headers = "# \(escapedMarkdown(title))\n## \(escapedMarkdown(show))"
        let body = (["*\(attribution)*"] + noteSections(notes).map(escapedMarkdown)).joined(separator: "\n\n")
        return headers + "\n\n" + body
    }

    private static func noteSections(_ notes: [EpisodeNoteRecord]) -> [String] {
        let wholeEpisode = notes.filter(\.isEpisodeWide).sorted { $0.createdAt < $1.createdAt }
        let timestamped = notes.filter { !$0.isEpisodeWide }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.noteID < $1.noteID
        }
        return wholeEpisode.map(\.text) + timestamped.map { "\($0.timestamp.formattedPlaybackDuration)\n\($0.text)" }
    }

    private static func escapedMarkdown(_ text: String) -> String {
        let special = Set("\\`*_{}[]<>()#+-.!|~")
        return text.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
            .replacingOccurrences(of: "\n", with: "  \n")
    }
}
