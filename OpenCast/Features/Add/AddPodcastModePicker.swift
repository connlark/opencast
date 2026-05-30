import SwiftUI

struct AddPodcastModePicker: View {
    @Binding var selectedMode: AddPodcastMode

    var body: some View {
        Picker("Add Method", selection: $selectedMode) {
            ForEach(AddPodcastMode.allCases) { mode in
                switch mode {
                case .rss:
                    Label("RSS", systemImage: "dot.radiowaves.right")
                        .tag(mode)
                case .search:
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(mode)
                }
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("Add Podcast Mode")
    }
}
