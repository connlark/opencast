import SwiftUI

/// The Shows chip: a checklist of subscribed shows under "All Shows". All
/// Shows is on only while the rule names no shows, so new subscriptions join
/// it; picking one show narrows the rule to that show, and unchecking the
/// last listed show returns to All Shows. The only chip that reads the
/// library, so subscription changes re-render this chip alone.
struct PlaylistShowsRuleMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        let title = rule.showsTitle(subscribedPodcastIDs: appModel.library.activePodcastIDs)
        Menu {
            Toggle("All Shows", systemImage: "books.vertical", isOn: allShowsBinding)
            Section("From Shows") {
                ForEach(shows, id: \.feedURL) { show in
                    Toggle(show.title, isOn: showBinding(for: show.feedURL))
                }
                .menuActionDismissBehavior(.disabled)
            }
        } label: {
            PlaylistRuleChipLabel(title: title, systemImage: "books.vertical")
        }
        .smartRuleChipMenu(clause: "Shows", title: title)
    }

    /// Subscribed shows in the Library's title order, one row per feed even
    /// while sync twins of a subscription are waiting for repair.
    private var shows: [(feedURL: String, title: String)] {
        var seenFeedURLs = Set<String>()
        return appModel.library.subscriptions.compactMap { subscription in
            guard seenFeedURLs.insert(subscription.feedURL).inserted else {
                return nil
            }
            return (feedURL: subscription.feedURL, title: subscription.title)
        }
    }

    private var allShowsBinding: Binding<Bool> {
        Binding {
            rule.podcastIDs == nil
        } set: { isOn in
            guard isOn else {
                return
            }
            var updated = rule
            updated.podcastIDs = nil
            onChange(updated.normalized())
        }
    }

    private func showBinding(for feedURL: String) -> Binding<Bool> {
        Binding {
            rule.podcastIDs?.contains(feedURL) == true
        } set: { isOn in
            setShow(feedURL, included: isOn)
        }
    }

    private func setShow(_ feedURL: String, included: Bool) {
        var updated = rule
        if included {
            updated.podcastIDs = (rule.podcastIDs ?? []) + [feedURL]
        } else {
            let subscribedIDs = appModel.library.activePodcastIDs
            let remaining = (rule.podcastIDs ?? []).filter { podcastID in
                podcastID != feedURL && subscribedIDs.contains(podcastID)
            }
            updated.podcastIDs = remaining.isEmpty ? nil : remaining
        }
        onChange(updated.normalized())
    }
}
