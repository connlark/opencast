import SwiftUI

/// Make a Playlist from the Playlists collection. The organizer drafts from
/// one show, so this sheet asks which; the presenter dismisses it and opens
/// the organizer for the chosen show.
struct PlaylistOrganizerShowPickerSheet: View {
    /// Past this many shows the search field stays visible.
    private static let alwaysVisibleSearchShowCount = 8

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let onChoose: (String) -> Void

    /// Nil while loading. Captured once, so a refresh never reorders rows
    /// under a finger.
    @State private var choices: [PlaylistOrganizerShowChoice]?
    @State private var query = ""

    var body: some View {
        let filtered = choices?.filter { $0.matches(query) } ?? []
        let isLong = (choices?.count ?? 0) > Self.alwaysVisibleSearchShowCount

        NavigationStack {
            List {
                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered) { choice in
                            PlaylistOrganizerShowChoiceRow(choice: choice) {
                                onChoose(choice.podcastID)
                            }
                        }
                    } footer: {
                        Text(PlaylistOrganizerCopy.showPickerFooter)
                    }
                }
            }
            .accessibilityIdentifier("Playlist Organizer Show Picker")
            .overlay {
                placeholder(isFilteredEmpty: filtered.isEmpty)
            }
            .navigationTitle(PlaylistOrganizerCopy.showPickerTitle)
            .navigationSubtitle(PlaylistOrganizerCopy.showPickerSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: isLong ? .always : .automatic),
                prompt: Text(PlaylistOrganizerCopy.showPickerSearchPrompt)
            )
        }
        .task {
            loadChoices()
        }
    }

    @ViewBuilder
    private func placeholder(isFilteredEmpty: Bool) -> some View {
        if let choices {
            if choices.isEmpty {
                ContentUnavailableView(
                    PlaylistOrganizerCopy.showPickerEmptyTitle,
                    systemImage: "books.vertical",
                    description: Text(PlaylistOrganizerCopy.showPickerEmptyMessage)
                )
            } else if isFilteredEmpty {
                ContentUnavailableView.search
            }
        } else {
            ProgressView()
        }
    }

    private func loadChoices() {
        let library = appModel.library
        choices = PlaylistOrganizerShowChoiceBuilder.make(
            subscriptions: library.subscriptions,
            podcastCache: library.podcastCache(for:),
            episodeCount: library.episodeCount(forPodcastID:)
        )
    }
}
