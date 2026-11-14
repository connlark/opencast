import Foundation
import OpenCastCore

nonisolated struct EpisodeShowNotesContent: Equatable, Sendable {
    let blocks: [AttributedString]
    /// The episode this was resolved for; nil for `.empty`.
    let episodeID: String?
    /// Private, so the only way to the list is `chapters(for:)`: the content
    /// outlives an episode change until the new one resolves.
    private let derivedChapters: [EpisodeChapter]

    static let empty = EpisodeShowNotesContent(blocks: [], episodeID: nil, derivedChapters: [])

    var isEmpty: Bool {
        blocks.isEmpty
    }

    /// The chapters derived from these notes, and only for the episode they
    /// were resolved for; another episode gets none.
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

    /// The same derivation off the caller's actor, for callers that need the
    /// chapters without the rendered notes.
    @concurrent
    static func resolvingChapters(
        summaryHTML: String?,
        showNotesHTML: String?,
        duration: TimeInterval?
    ) async -> [EpisodeChapter] {
        derivedChapters(summaryHTML: summaryHTML, showNotesHTML: showNotesHTML, duration: duration)
    }

    /// The one place the app decides which text a chapter list is read from,
    /// so every surface reads the same one: the notes when they hold a list,
    /// else the summary. A feed can ship its notes as escaped markup that
    /// hides the list while its summary carries it clean. An episode with no
    /// `content:encoded` has its summary copied into the notes, so the
    /// summary is read only when it differs.
    static func derivedChapters(
        summaryHTML: String?,
        showNotesHTML: String?,
        duration: TimeInterval?
    ) -> [EpisodeChapter] {
        let texts = summaryHTML == showNotesHTML ? [showNotesHTML] : [showNotesHTML, summaryHTML]
        for html in texts.compactMap({ $0 }) {
            let chapters = ShowNotesChaptersParser.chapters(
                in: HTMLPlainText.structuredText(from: html),
                duration: duration
            )
            if !chapters.isEmpty {
                return chapters
            }
        }
        return []
    }
}
