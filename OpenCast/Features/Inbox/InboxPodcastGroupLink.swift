import SwiftData
import SwiftUI

/// A show in the Group by Podcast Inbox, around a row or a tile. It opens the
/// show under the Inbox's settings, so the show lists the episodes the count
/// stood for, and a long press acts on those episodes. Unlike a Library cell
/// it offers no removal: the Inbox is not where shows are managed.
struct InboxPodcastGroupLink<Content: View>: View {
    let group: InboxPodcastGroup
    let episodeListOverride: PodcastEpisodeListOverride
    var selectionStyle: TwoPaneRootSelectionStyle = .listRow
    @ViewBuilder let content: Content

    var body: some View {
        TwoPaneRootLink(
            route: .podcastDetail(
                feedURL: group.subscription.feedURL,
                episodeListOverride: episodeListOverride
            ),
            selectionStyle: selectionStyle
        ) {
            content
        }
        .accessibilityValue(Text("^[\(group.episodeCount) episode](inflect: true)"))
        .accessibilityIdentifier("inbox-podcast-group-\(group.subscription.feedURL)")
        .modifier(InboxPodcastGroupActionsModifier(group: group, episodeListOverride: episodeListOverride))
    }
}
