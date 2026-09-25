import SwiftUI

/// The glass filter menu shared by the podcast episode list and the Inbox.
/// `menuExtras` appends screen-specific items below the filter picker.
struct EpisodeFilterMenu<MenuExtras: View>: View {
    @Binding var filter: PodcastEpisodeFilter
    private let menuExtras: MenuExtras

    init(filter: Binding<PodcastEpisodeFilter>, @ViewBuilder menuExtras: () -> MenuExtras) {
        _filter = filter
        self.menuExtras = menuExtras()
    }

    var body: some View {
        Menu {
            Picker("Filter Episodes", selection: $filter) {
                ForEach(PodcastEpisodeFilter.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            menuExtras
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

extension EpisodeFilterMenu where MenuExtras == EmptyView {
    init(filter: Binding<PodcastEpisodeFilter>) {
        self.init(filter: filter) {
            EmptyView()
        }
    }
}
