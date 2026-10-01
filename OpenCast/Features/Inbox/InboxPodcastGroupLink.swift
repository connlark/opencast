import SwiftData
import SwiftUI

/// A show in the Group by Podcast Inbox, around a row or a tile. It opens the
/// show under the Inbox's settings, so the show lists the episodes the count
/// stood for. Unlike a Library cell it offers no removal: the Inbox is not
/// where shows are managed.
struct InboxPodcastGroupLink<Content: View>: View {
    let group: InboxPodcastGroup
    let episodeListOverride: PodcastEpisodeListOverride
    @ViewBuilder let content: Content

    var body: some View {
        NavigationLink(
            value: AppRoute.podcastDetail(
                feedURL: group.subscription.feedURL,
                episodeListOverride: episodeListOverride
            )
        ) {
            content
        }
        .accessibilityValue(Text("^[\(group.episodeCount) episode](inflect: true)"))
        .accessibilityIdentifier("inbox-podcast-group-\(group.subscription.feedURL)")
    }
}
