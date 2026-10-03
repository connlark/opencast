import SwiftUI

/// Picks the shows a smart playlist draws from. All Shows is on only while
/// the rule names no shows, so new subscriptions join it; picking a show
/// narrows the rule to the listed shows, and unchecking the last listed show
/// returns to All Shows. Each pick reports the new rule at once through
/// `onChange`, and the rows read the rule the sheet is handed, so the list
/// updates in place and keeps its scroll position.
struct PlaylistShowsPickerSheet: View {
    /// Above this many shows the search field stays in view.
    private static let searchThreshold = 10

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        @Bindable var appModel = appModel
        let shows = subscribedShows

        NavigationStack {
            // Always attached: removing a conditional `.searchable` mid-update
            // can strand the system's search dismissal. A short list only
            // tucks the field away until the listener pulls down.
            showList(shows)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(
                        displayMode: shows.count > Self.searchThreshold ? .always : .automatic
                    ),
                    prompt: "Search Shows"
                )
                .navigationTitle("Shows")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: rule.podcastIDs)
        // The root's playlist alert cannot present over a sheet, so a save
        // that fails while the picker is up surfaces here.
        .alert("Playlist Error", item: $appModel.lastPlaylistError) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func showList(_ shows: [SubscriptionRecord]) -> some View {
        let matches = searchText.isEmpty
            ? shows
            : shows.filter { $0.title.localizedStandardContains(searchText) }
        let pickedIDs = Set(rule.podcastIDs ?? [])

        return List {
            if searchText.isEmpty {
                Section {
                    PlaylistShowsPickerRow(
                        title: "All Shows",
                        isSelected: rule.podcastIDs == nil,
                        identifier: "all",
                        action: pickAllShows
                    ) {
                        Image(systemName: "books.vertical")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.tint.quaternary, in: .rect(cornerRadius: 8))
                    }
                } footer: {
                    Text("Shows you subscribe to later join All Shows.")
                }
            }

            Section("From Shows") {
                ForEach(matches, id: \.feedURL) { show in
                    PlaylistShowsPickerRow(
                        title: show.title,
                        isSelected: pickedIDs.contains(show.feedURL),
                        identifier: show.feedURL,
                        action: { toggle(show.feedURL) }
                    ) {
                        artwork(for: show)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if matches.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .accessibilityIdentifier("Shows Picker")
    }

    private func artwork(for show: SubscriptionRecord) -> some View {
        let podcastCache = appModel.library.podcastCache(for: show.feedURL)
        return ArtworkPlaceholder(
            title: show.title,
            imageURL: podcastCache?.artworkURL ?? show.artworkURL,
            size: 40,
            preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
        )
        .clipShape(.rect(cornerRadius: 8))
    }

    /// Subscribed shows in the Library's title order, one row per feed even
    /// while sync twins of a subscription are waiting for repair.
    private var subscribedShows: [SubscriptionRecord] {
        var seenFeedURLs = Set<String>()
        return appModel.library.subscriptions.filter { subscription in
            seenFeedURLs.insert(subscription.feedURL).inserted
        }
    }

    private func pickAllShows() {
        guard rule.podcastIDs != nil else {
            return
        }
        var updated = rule
        updated.podcastIDs = nil
        onChange(updated.normalized())
    }

    private func toggle(_ feedURL: String) {
        var updated = rule
        if rule.podcastIDs?.contains(feedURL) == true {
            let subscribedIDs = appModel.library.activePodcastIDs
            let remaining = (rule.podcastIDs ?? []).filter { podcastID in
                podcastID != feedURL && subscribedIDs.contains(podcastID)
            }
            updated.podcastIDs = remaining.isEmpty ? nil : remaining
        } else {
            updated.podcastIDs = (rule.podcastIDs ?? []) + [feedURL]
        }
        onChange(updated.normalized())
    }
}
