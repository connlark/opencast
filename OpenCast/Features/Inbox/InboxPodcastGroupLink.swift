import SwiftData
import SwiftUI

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
