import Foundation

/// One subscribed show in the Make a Playlist show picker, captured once
/// when the picker opens so a library refresh never reorders its rows.
nonisolated struct PlaylistOrganizerShowChoice: Identifiable, Equatable, Sendable {
    let podcastID: String
    let title: String
    let author: String?
    let artworkURL: String?
    let artworkPreview: ArtworkPreview?
    let episodeCount: Int

    var id: String { podcastID }
    var isEligible: Bool { episodeCount >= PlaylistOrganizerFeatureFlags.minimumEpisodeCount }

    /// Empty and whitespace queries match every show.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        return title.localizedStandardContains(trimmed) || author?.localizedStandardContains(trimmed) == true
    }
}
