import SwiftUI

struct DownloadSettingsShowRow: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let subscription: SubscriptionRecord

    private var summary: String {
        let settings = appModel.downloadSettings
        let automation = if settings.detectsAdsInNewEpisodes(forPodcastID: subscription.feedURL) {
            "Downloads and detects ads"
        } else if settings.autoDownloadsNewEpisodes(forPodcastID: subscription.feedURL) {
            "Downloads new episodes"
        } else {
            "Manual"
        }
        let keepLimit = settings.keepLimitOverride(forPodcastID: subscription.feedURL)?.shortTitle
            ?? "Default (\(settings.defaultKeepLimit.title))"
        return "\(automation) · \(keepLimit)"
    }

    var body: some View {
        SettingsShowLabel(subscription: subscription, summary: summary)
    }
}
