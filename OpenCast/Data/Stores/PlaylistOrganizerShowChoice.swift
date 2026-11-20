import Foundation

nonisolated struct PlaylistOrganizerShowChoice: Identifiable, Equatable, Sendable {
    let podcastID: String
    let title: String
    let author: String?
    let artworkURL: String?
    let artworkPreview: ArtworkPreview?
    let episodeCount: Int

    var id: String { podcastID }
    var isEligible: Bool { episodeCount >= PlaylistOrganizerFeatureFlags.minimumEpisodeCount }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        return title.localizedStandardContains(trimmed) || author?.localizedStandardContains(trimmed) == true
    }
}
