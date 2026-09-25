import SwiftUI

/// The episode filter choices, shared by the podcast episode list's glass
/// menu and the Inbox toolbar menu.
struct EpisodeFilterPicker: View {
    @Binding var filter: PodcastEpisodeFilter

    var body: some View {
        Picker("Filter Episodes", selection: $filter) {
            ForEach(PodcastEpisodeFilter.allCases) { option in
                Label(option.title, systemImage: option.systemImage)
                    .tag(option)
            }
        }
    }
}
