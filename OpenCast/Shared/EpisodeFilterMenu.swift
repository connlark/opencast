import SwiftUI

/// The podcast episode list's glass filter menu, beside its sort menu.
struct EpisodeFilterMenu: View {
    @Binding var filter: PodcastEpisodeFilter

    var body: some View {
        Menu {
            EpisodeFilterPicker(filter: $filter)
        } label: {
            Label(filter.title, systemImage: filter.systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Filter Episodes, \(filter.title)")
    }
}
