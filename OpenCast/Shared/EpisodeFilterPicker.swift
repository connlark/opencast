import SwiftUI

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
