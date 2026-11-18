import SwiftUI

/// A show in Download Settings: whether it downloads new episodes, and
/// scans them for ads, and the Keep Downloaded choice it has, or the
/// default it follows.
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
