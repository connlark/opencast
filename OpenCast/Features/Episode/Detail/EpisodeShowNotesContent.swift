import Foundation

struct EpisodeShowNotesContent: Equatable, Sendable {
    let blocks: [AttributedString]

    static let empty = EpisodeShowNotesContent(blocks: [])

    var isEmpty: Bool {
        blocks.isEmpty
    }

    @concurrent
    static func resolving(summaryHTML: String?, showNotesHTML: String?) async -> EpisodeShowNotesContent {
        if let showNotes = showNotesHTML.map(HTMLAttributedText.attributedBlocks), !showNotes.isEmpty {
            return EpisodeShowNotesContent(blocks: showNotes)
        }

        return EpisodeShowNotesContent(blocks: summaryHTML.map(HTMLAttributedText.attributedBlocks) ?? [])
    }
}
