import SwiftUI

/// The Episodes chip: the played-state filter, then Downloaded Only as its
/// own clause, so "unplayed and downloaded" is one rule.
struct PlaylistEpisodesRuleMenu: View {
    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        Menu {
            EpisodeFilterPicker(filter: statusBinding, options: PlaylistRule.statusOptions)
            Divider()
            Toggle("Downloaded Only", systemImage: "arrow.down.circle", isOn: downloadedOnlyBinding)
        } label: {
            PlaylistRuleChipLabel(title: rule.episodesTitle, systemImage: rule.episodesSystemImage)
        }
        .smartRuleChipMenu(clause: "Episodes", title: rule.episodesTitle)
    }

    private var statusBinding: Binding<PodcastEpisodeFilter> {
        Binding {
            rule.status
        } set: { status in
            var updated = rule
            updated.status = status
            onChange(updated.normalized())
        }
    }

    private var downloadedOnlyBinding: Binding<Bool> {
        Binding {
            rule.downloadedOnly
        } set: { downloadedOnly in
            var updated = rule
            updated.downloadedOnly = downloadedOnly
            onChange(updated.normalized())
        }
    }
}
