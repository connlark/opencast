import Foundation

nonisolated struct EpisodeShowNotesBlock: Identifiable, Equatable, Sendable {
    nonisolated struct ID: Hashable, Sendable {
        let content: AttributedString
        let occurrence: Int
    }

    let id: ID
    let content: AttributedString

    static func identify(_ blocks: [AttributedString]) -> [EpisodeShowNotesBlock] {
        var occurrences: [AttributedString: Int] = [:]
        return blocks.map { content in
            let occurrence = occurrences[content, default: 0]
            occurrences[content] = occurrence + 1
            return EpisodeShowNotesBlock(
                id: ID(content: content, occurrence: occurrence),
                content: content
            )
        }
    }
}
