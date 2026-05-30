#if DEBUG
import Foundation

struct AppStoreScreenshotSeedEpisode: Identifiable {
    let id: String
    let title: String
    let summary: String
    let showNotesHTML: String
    let publishedAt: Date
    let duration: TimeInterval
    let position: TimeInterval?
    let isPlayed: Bool
}
#endif
