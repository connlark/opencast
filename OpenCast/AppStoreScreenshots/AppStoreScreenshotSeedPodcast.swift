#if DEBUG
import Foundation

struct AppStoreScreenshotSeedPodcast: Identifiable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let websiteURL: String
    let artworkName: String
    let episodes: [AppStoreScreenshotSeedEpisode]
}
#endif
