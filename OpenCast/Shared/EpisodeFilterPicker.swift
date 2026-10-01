import SwiftUI

/// The episode filter choices, shared by the podcast episode list's glass
/// menu, the Inbox toolbar menu and a smart playlist's Episodes chip, which
/// passes `PlaylistRule.statusOptions` because Downloaded Only is its own
/// toggle there.
struct EpisodeFilterPicker: View {
    @Binding var filter: PodcastEpisodeFilter
    var options: [PodcastEpisodeFilter] = PodcastEpisodeFilter.allCases

    var body: some View {
        Picker("Filter Episodes", selection: $filter) {
            ForEach(options) { option in
                Label(option.title, systemImage: option.systemImage)
                    .tag(option)
            }
        }
    }
}
