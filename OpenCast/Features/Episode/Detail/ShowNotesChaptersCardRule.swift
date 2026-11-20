import Foundation
import OpenCastCore

/// Show-notes chapters rank last, so they wait until every higher-ranked source has settled
/// empty: chapters about to land must not be preceded by a flash of the show-notes list.
nonisolated enum ShowNotesChaptersCardRule {
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
