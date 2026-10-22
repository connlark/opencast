import SwiftUI

/// Ranks the shows whose episodes lead a smart playlist. The First section
/// holds the ranked shows in order, with reorder handles; the shows below
/// are the rule's other candidates, the listed shows or every subscription.
/// Tapping a show adds it to the end of First or removes it. Each change
/// reports the new rule at once through `onChange`, and the rows read the
/// rule the sheet is handed, so the list updates in place and keeps its
/// scroll position.
struct PlaylistPriorityPickerSheet: View {
    /// Above this many shows the search field stays in view.
    private static let searchThreshold = 10

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        @Bindable var appModel = appModel
        let candidates = candidateShows

        NavigationStack {
            // Always attached: removing a conditional `.searchable` mid-update
            // can strand the system's search dismissal. A short list only
            // tucks the field away until the listener pulls down.
            showList(candidates)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(
                        displayMode: candidates.count > Self.searchThreshold ? .always : .automatic
                    ),
                    prompt: "Search Shows"
                )
                .navigationTitle("Priority")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: rule.priorityPodcastIDs)
        // The root's playlist alert cannot present over a sheet, so a save
        // that fails while the picker is up surfaces here.
        .alert("Playlist Error", item: $appModel.lastPlaylistError) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func showList(_ candidates: [SubscriptionRecord]) -> some View {
        let first = firstShows(among: candidates)
        let firstIDs = Set(first.map(\.feedURL))
        let others = candidates.filter { !firstIDs.contains($0.feedURL) }
        let matches = searchText.isEmpty
            ? others
            : others.filter { $0.title.localizedStandardContains(searchText) }

        return List {
            if searchText.isEmpty, !first.isEmpty {
                Section {
                    // A different identity from the Shows rows below, so a
                    // show changing sections is a removal and an insertion.
                    // As a move, the cell kept its Shows configuration and a
                    // newly ranked row had no reorder handle.
                    ForEach(first, id: \.priorityPickerFirstRowID) { show in
                        PlaylistShowsPickerRow(
                            title: show.title,
                            accessory: .remove,
                            identifier: "priority-picker-first-\(show.feedURL)",
                            action: { remove(show.feedURL, from: first) }
                        ) {
                            PlaylistShowsPickerArtwork(show: show)
                        }
                    }
                    .onMove { offsets, destination in
                        move(first, fromOffsets: offsets, toOffset: destination)
                    }
                } header: {
                    Text("First")
                } footer: {
                    Text("Episodes from these shows come first, in this order. Drag to reorder; tap a show to remove it.")
                }
            }

            if !matches.isEmpty {
                Section {
                    ForEach(matches, id: \.feedURL) { show in
                        PlaylistShowsPickerRow(
                            title: show.title,
                            accessory: .add,
                            identifier: "priority-picker-row-\(show.feedURL)",
                            action: { add(show.feedURL, to: first) }
                        ) {
                            PlaylistShowsPickerArtwork(show: show)
                        }
                    }
                } header: {
                    Text("Shows")
                } footer: {
                    if searchText.isEmpty {
                        Text("Tap a show to play its episodes before the rest of the playlist.")
                    }
                }
            }
        }
        // Always editing, so the First rows show their reorder handles
        // without an Edit button. Only that section has `onMove`, and there
        // is no `onDelete`, so no other row gains an editing control.
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Shows",
                    systemImage: "books.vertical",
                    description: Text("This playlist has no shows to prioritize.")
                )
            } else if matches.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .accessibilityIdentifier("Priority Picker")
    }

    /// Subscribed shows the rule draws from, in the Library's title order.
    private var candidateShows: [SubscriptionRecord] {
        let shows = appModel.library.uniqueSubscriptions
        guard let podcastIDs = rule.podcastIDs else {
            return shows
        }
        let listedIDs = Set(podcastIDs)
        return shows.filter { listedIDs.contains($0.feedURL) }
    }

    /// The ranked shows in rank order. A ranked show that is no longer a
    /// candidate drops out of the display, and the next edit prunes it.
    private func firstShows(among candidates: [SubscriptionRecord]) -> [SubscriptionRecord] {
        let showsByFeedURL = Dictionary(candidates.map { ($0.feedURL, $0) }, uniquingKeysWith: { first, _ in first })
        return (rule.priorityPodcastIDs ?? []).compactMap { showsByFeedURL[$0] }
    }

    // Each edit rebuilds the list from the displayed First rows, so the
    // `onMove` offsets always match it.

    private func add(_ feedURL: String, to first: [SubscriptionRecord]) {
        commit(first.map(\.feedURL) + [feedURL])
    }

    private func remove(_ feedURL: String, from first: [SubscriptionRecord]) {
        commit(first.map(\.feedURL).filter { $0 != feedURL })
    }

    private func move(_ first: [SubscriptionRecord], fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var feedURLs = first.map(\.feedURL)
        feedURLs.move(fromOffsets: offsets, toOffset: destination)
        commit(feedURLs)
    }

    private func commit(_ priorityPodcastIDs: [String]) {
        var updated = rule
        updated.priorityPodcastIDs = priorityPodcastIDs
        onChange(updated.normalized())
    }
}

private extension SubscriptionRecord {
    var priorityPickerFirstRowID: String {
        "first-\(feedURL)"
    }
}
