import Foundation
import OpenCastCore

/// When the episode screen renders chapters read from the show notes.
/// They rank last, so the card waits until every higher-ranked source has
/// settled without chapters of its own: one about to land must not be
/// preceded by a flash of the show-notes list on every open.
nonisolated enum ShowNotesChaptersCardRule {
    /// The chapters to render, or none. `awaitsEmbeddedRead`: the episode
    /// has a download whose embedded-chapter read has not landed.
    /// `awaitsGeneratedChapters`: a completed analysis whose section load
    /// has not landed under the current key.
    static func chapters(
        from showNotes: EpisodeShowNotesContent,
        episodeID: String,
        displaysEmbeddedChapters: Bool,
        awaitsEmbeddedRead: Bool,
        publisherHasFinished: Bool,
        publisherHasChapters: Bool,
        rendersGeneratedChapters: Bool,
        awaitsGeneratedChapters: Bool
    ) -> [EpisodeChapter] {
        guard !displaysEmbeddedChapters, !awaitsEmbeddedRead,
              publisherHasFinished, !publisherHasChapters,
              !rendersGeneratedChapters, !awaitsGeneratedChapters
        else {
            return []
        }
        return showNotes.chapters(for: episodeID)
    }
}
