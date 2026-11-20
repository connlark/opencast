import Foundation
import OpenCastCore

nonisolated struct EpisodeShowNotesContent: Equatable, Sendable {
    let blocks: [AttributedString]
    let episodeID: String?
    /// Private, so the only way to the list is `chapters(for:)`: the content
    /// outlives an episode change until the new one resolves.
    private let derivedChapters: [EpisodeChapter]

    static let empty = EpisodeShowNotesContent(blocks: [], episodeID: nil, derivedChapters: [])

    var isEmpty: Bool {
        blocks.isEmpty
    }

    func chapters(for episodeID: String) -> [EpisodeChapter] {
        self.episodeID == episodeID ? derivedChapters : []
    }

    @concurrent
    static func resolving(
        episodeID: String,
        summaryHTML: String?,
        showNotesHTML: String?,
        duration: TimeInterval?
    ) async -> EpisodeShowNotesContent {
        let blocks = if let showNotes = showNotesHTML.map(HTMLAttributedText.attributedBlocks), !showNotes.isEmpty {
            showNotes
        } else {
            summaryHTML.map(HTMLAttributedText.attributedBlocks) ?? []
        }
        return EpisodeShowNotesContent(
            blocks: blocks,
            episodeID: episodeID,
            derivedChapters: derivedChapters(summaryHTML: summaryHTML, showNotesHTML: showNotesHTML, duration: duration)
        )
    }

    @concurrent
    static func resolvingChapters(
        summaryHTML: String?,
        showNotesHTML: String?,
        duration: TimeInterval?
    ) async -> [EpisodeChapter] {
        derivedChapters(summaryHTML: summaryHTML, showNotesHTML: showNotesHTML, duration: duration)
    }

    /// The summary is a fallback because a feed can ship escaped notes that hide a list its
    /// summary carries clean. With no `content:encoded` the notes are a copy of the summary.
    static func derivedChapters(
        summaryHTML: String?,
        showNotesHTML: String?,
        duration: TimeInterval?
    ) -> [EpisodeChapter] {
        let texts = summaryHTML == showNotesHTML ? [showNotesHTML] : [showNotesHTML, summaryHTML]
        return ShowNotesChaptersParser.chapters(
            in: texts.lazy.compactMap { $0 }.map(HTMLPlainText.structuredText),
            duration: duration
        )
    }
}
