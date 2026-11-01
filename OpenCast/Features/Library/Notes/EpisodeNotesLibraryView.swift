import SwiftData
import SwiftUI

/// Every Private Note, one section per episode under a header that opens the
/// episode, with a search over note text and titles and a sort. The notes are
/// fetched again only when a note changes; search and sort regroup the
/// fetched notes.
struct EpisodeNotesLibraryView: View {
    /// Above this many notes the search field stays in view.
    private static let searchThreshold = 10

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var actions = EpisodeNotesActions()
    @State private var notes: [EpisodeNoteRecord] = []
    /// Set by the first fetch that succeeds and never reset; the empty state
    /// waits for it.
    @State private var hasLoaded = false
    /// Why the last fetch failed; only a successful fetch clears it, so
    /// dismissing the alert never brings back an empty state it contradicts.
    @State private var loadError: String?
    @State private var groups: [EpisodeNotesLibraryGroup] = []
    @State private var searchText = ""
    @State private var sortOrder = EpisodeNotesLibrarySortOrder.recent
    @State private var playErrorMessage: String?
    @State private var loadErrorMessage: String?

    let onOpenEpisode: (String) -> Void

    var body: some View {
        List {
            ForEach(groups, content: section)
        }
        .accessibilityIdentifier("Notes Library List")
        .overlay {
            emptyState
        }
        .navigationTitle("Notes")
        // Always attached: removing a conditional `.searchable` mid-update
        // can strand the system's search dismissal. A short list only tucks
        // the field away until the listener pulls down.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(
                displayMode: notes.count > Self.searchThreshold ? .always : .automatic
            ),
            prompt: "Search Notes"
        )
        .toolbar {
            if !notes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
                .visibilityPriority(.low)
            }
        }
        .episodeNotesActions(actions)
        .alert("Couldn’t Play Episode", item: $playErrorMessage) { _ in
        } message: { message in
            Text(message)
        }
        .alert("Couldn’t Load Notes", item: $loadErrorMessage) { _ in
        } message: { message in
            Text(message)
        }
        .task(id: appModel.episodeNotes.allNotesRevision) {
            loadNotes()
        }
        .task(id: groupingKey) {
            regroup()
        }
    }

    private func section(for group: EpisodeNotesLibraryGroup) -> some View {
        Section {
            EpisodeNotesLibraryEpisodeHeader(group: group, onOpen: onOpenEpisode)
            ForEach(group.notes) { note in
                EpisodeNoteListRow(
                    note: note,
                    onSeek: { seek(to: $0, episodeID: group.episodeID) },
                    onEdit: edit,
                    onDelete: delete
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let loadError, notes.isEmpty {
            ContentUnavailableView(
                "Couldn’t Load Notes",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if loadError == nil, hasLoaded, notes.isEmpty {
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "note.text",
                description: Text("Add a note from Now Playing, or an episode note from the episode's actions menu.")
            )
        } else if groups.isEmpty, !notes.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(EpisodeNotesLibrarySortOrder.allCases) { order in
                    Text(order.title)
                        .tag(order)
                }
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("Notes Sort Menu")
        .sensoryFeedback(.selection, trigger: sortOrder)
    }

    /// The library's episodes and downloads decide which notes resolve, so
    /// they regroup the notes too.
    private var groupingKey: EpisodeNotesLibraryGroupingKey {
        EpisodeNotesLibraryGroupingKey(
            query: searchText,
            sortOrder: sortOrder,
            episodesRevision: appModel.library.episodeSearchCorpusRevision,
            downloadsRevision: appModel.downloads.recordsRevision
        )
    }

    private func loadNotes() {
        let fetched: [EpisodeNoteRecord]
        do {
            fetched = try modelContext.fetch(EpisodeNoteStore.allNotes())
        } catch {
            // The notes from the last fetch that worked stay on screen, with
            // the alert; with none to keep, the empty state shows the error.
            loadError = error.localizedDescription
            loadErrorMessage = notes.isEmpty ? nil : loadError
            return
        }
        // A failed backfill puts the notes back as they were: the headers
        // fall back to the resolved episode and the next load tries again.
        try? EpisodeNoteStore.backfillEpisodeInfo(fetched, resolve: appModel.episodeSnapshot(for:), in: modelContext)
        notes = fetched
        regroup()
        loadError = nil
        loadErrorMessage = nil
        hasLoaded = true
    }

    private func regroup() {
        groups = EpisodeNotesLibraryGrouping.groups(
            from: notes,
            resolve: appModel.episodeSnapshot(for:),
            matching: searchText,
            sortedBy: sortOrder
        )
    }

    private func seek(to seconds: TimeInterval, episodeID: String) {
        guard let episode = appModel.episodeSnapshot(for: episodeID) else {
            playErrorMessage = "This episode is no longer in your library."
            return
        }
        do {
            try EpisodeTimestampPlayback.seek(to: seconds, episode: episode, appModel: appModel, modelContext: modelContext)
        } catch {
            playErrorMessage = error.localizedDescription
        }
    }

    private func edit(_ note: EpisodeNoteRecord) {
        actions.edit(note, episode: appModel.episodeSnapshot(for: note.episodeID))
    }

    /// The deleted note leaves the screen at once, so a refetch that then
    /// fails keeps only the notes that still exist.
    private func delete(_ note: EpisodeNoteRecord) {
        let episodeID = note.episodeID
        guard actions.delete(note, in: modelContext) else {
            return
        }
        notes.removeAll { $0 === note }
        regroup()
        appModel.episodeNotes.notesDidChange(episodeID: episodeID)
    }
}
