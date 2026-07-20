import Foundation

struct PodcastEpisodeListSettingsError: Equatable {
    let message: String
    let podcastID: String?

    func message(forPodcastID podcastID: String) -> String? {
        guard self.podcastID == nil || self.podcastID == podcastID else {
            return nil
        }
        return message
    }

    func clearing(forPodcastID podcastID: String) -> Self? {
        self.podcastID == podcastID ? nil : self
    }
}
