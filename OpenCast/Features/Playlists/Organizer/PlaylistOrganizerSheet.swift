import OSLog
import SwiftData
import SwiftUI

/// Make a Playlist for one show. The listener types a playlist idea or asks
/// for suggested groups; Apple's Private Cloud Compute answers over the
/// show's episode list; the proposals are renamed, trimmed, reordered and
/// sorted here, then saved as ordinary manual playlists.
struct PlaylistOrganizerSheet: View {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "playlist-organizer")

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let podcastID: String

    @State private var phase = PlaylistOrganizerSheetPhase.request
    @State private var requestGeneration = 0
    @State private var requestText = ""
    @State private var suggestsGroups = false
    @State private var activeMode = PlaylistOrganizerMode.prompted
    @State private var show: PlaylistOrganizerShow?
    @State private var formScope: PlaylistOrganizerScope?
    @State private var suggestionFormScope: PlaylistOrganizerScope?
    @State private var resultScope: PlaylistOrganizerScope?
    @State private var drafts: [PlaylistProposalDraft] = []
    @State private var catalog: PlaylistOrganizerCatalog?
    @State private var addEpisodesRequest: PlaylistProposalAddEpisodesRequest?
    @State private var isConfirmingDiscard = false
    // The root's playlist alert cannot present over this sheet, so save
    // failures surface on the sheet itself.
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                content
            }
            .navigationTitle(PlaylistOrganizerCopy.sheetTitle)
            .navigationSubtitle(PlaylistOrganizerCopy.subtitle(showTitle: showTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .navigationDestination(item: $addEpisodesRequest) { request in
                addEpisodesView(for: request)
            }
        }
        .interactiveDismissDisabled(hasUnsavedProposals)
        .onChange(of: drafts.isEmpty) { _, isEmpty in
            returnToRequestIfEmptied(isEmpty)
        }
        .task {
            await prepareForm()
        }
        .task(id: requestGeneration) {
            await run()
        }
        .alert(PlaylistOrganizerCopy.saveErrorTitle, item: $errorMessage) { _ in
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .request:
            PlaylistOrganizerRequestForm(
                requestText: $requestText,
                suggestsGroups: $suggestsGroups,
                scope: suggestsGroups ? suggestionFormScope : formScope,
                canAsk: canAsk,
                onAsk: ask
            )
        case .loading(let startedAt):
            PlaylistOrganizerProgressView(startedAt: startedAt)
        case .proposals:
            PlaylistOrganizerProposalsList(
                drafts: $drafts,
                scope: resultScope,
                onAddEpisodes: showAddEpisodes
            )
        case .empty:
            if let resultScope {
                outcomeView(for: .empty(scope: resultScope))
            }
        case .outcome(let outcome):
            outcomeView(for: outcome)
        case .unavailable(let availability):
            TranscriptIntelligenceUnavailableView(
                availability: availability,
                featureName: PlaylistOrganizerCopy.featureName,
                offersLimitIncrease: appModel.transcriptIntelligence.quota.hasLimitIncreaseSuggestion,
                onRequestLimitIncrease: requestLimitIncrease
            )
            // A connection or a model that is still loading comes back on
            // its own; the typed request is kept for it.
            .safeAreaInset(edge: .bottom) {
                if availability == .offline || availability == .modelNotReady {
                    Button(PlaylistOrganizerCopy.tryAgain, action: tryAgain)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: cancel)
                .confirmationDialog(
                    PlaylistOrganizerCopy.discardTitle,
                    isPresented: $isConfirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button(PlaylistOrganizerCopy.discardConfirm, role: .destructive, action: dismiss.callAsFunction)
                    Button(PlaylistOrganizerCopy.keepEditing, role: .cancel) {}
                }
        }
        if phase == .proposals {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .disabled(drafts.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) {
                let count = saveableCount
                Button(PlaylistOrganizerCopy.saveTitle(count: count), action: save)
                    .disabled(count == 0)
                    .accessibilityIdentifier("Playlist Organizer Save")
            }
        }
    }

    private func outcomeView(for outcome: PlaylistOrganizerOutcome) -> some View {
        PlaylistOrganizerOutcomeView(
            outcome: outcome,
            mode: activeMode,
            onTryAgain: tryAgain,
            onOtherMode: switchMode,
            onEditRequest: editRequest
        )
    }

    @ViewBuilder
    private func addEpisodesView(for request: PlaylistProposalAddEpisodesRequest) -> some View {
        if let show {
            PlaylistProposalAddEpisodesView(request: request, show: show, loadCatalog: loadCatalog) { episodes in
                appendEpisodes(episodes, toDraftWithID: request.draftID)
            }
        }
    }

    /// The captured show's title once it is prepared, so the library is
    /// read only until then.
    private var showTitle: String? {
        if let show {
            return show.title
        }
        let library = appModel.library
        return library.podcastCache(for: podcastID)?.title
            ?? library.subscriptions.first(where: { $0.feedURL == podcastID })?.title
    }

    private var trimmedRequest: String {
        requestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAsk: Bool {
        suggestsGroups || !trimmedRequest.isEmpty
    }

    private var hasUnsavedProposals: Bool {
        phase == .proposals && !drafts.isEmpty
    }

    private var saveableCount: Int {
        drafts.count { $0.isSaveable }
    }

    // MARK: - Request

    private func prepareForm() async {
        guard let show = await preparedShow() else {
            return
        }
        let client = PlaylistOrganizerClient(store: appModel.transcriptIntelligence)
        let scope = await client.formScope(showTitle: show.title, episodes: show.episodes, mode: .prompted)
        // Only a show past the suggestion cap reads differently without a request.
        var suggestionScope = scope
        if show.episodes.count > PlaylistOrganizerInputBuilder.suggestionEpisodeLimit {
            suggestionScope = await client.formScope(showTitle: show.title, episodes: show.episodes, mode: .unprompted)
        }
        guard !Task.isCancelled else {
            return
        }
        formScope = scope
        suggestionFormScope = suggestionScope
    }

    /// Captured once per sheet; every request and the catalog read this list.
    private func preparedShow() async -> PlaylistOrganizerShow? {
        if let show {
            return show
        }
        let library = appModel.library
        let snapshots = library.episodes(forPodcastID: podcastID)
        let podcast = library.podcastCache(for: podcastID)
        let title = podcast?.title
            ?? library.subscriptions.first(where: { $0.feedURL == podcastID })?.title
            ?? snapshots.first?.podcastTitle
            ?? ""
        let summaries = await library.episodeSummaries(forPodcastID: podcastID) ?? [:]
        let episodes = await PlaylistOrganizerInputBuilder.episodes(
            from: snapshots,
            summaryHTMLByEpisodeID: summaries
        )
        guard !Task.isCancelled else {
            return nil
        }
        let prepared = PlaylistOrganizerShow(
            title: title,
            episodes: episodes,
            snapshots: snapshots.map {
                PlaylistEpisodeArtworkFallback.episode($0, showArtworkURL: podcast?.artworkURL)
            }
        )
        show = prepared
        return prepared
    }

    private func run() async {
        guard requestGeneration > 0 else {
            return
        }
        let store = appModel.transcriptIntelligence
        store.refreshAvailability()
        guard store.availability == .available else {
            phase = .unavailable(store.availability)
            return
        }
        let mode: PlaylistOrganizerMode = suggestsGroups ? .unprompted : .prompted
        let prompt = mode == .prompted ? trimmedRequest : nil
        activeMode = mode
        phase = .loading(startedAt: .now)
        guard let show = await preparedShow() else {
            return
        }
        let request = PlaylistOrganizerRequest(
            podcastID: podcastID,
            showTitle: show.title,
            mode: mode,
            prompt: prompt
        )
        let outcome = await PlaylistOrganizerClient(store: store).organize(
            request,
            episodes: show.episodes,
            snapshotsByEpisodeID: show.snapshotsByEpisodeID
        )
        // Dismissing the sheet cancels this task but not the model turn.
        guard !Task.isCancelled else {
            return
        }
        present(outcome, availability: store.availability)
    }

    private func present(_ outcome: PlaylistOrganizerOutcome, availability: TranscriptIntelligenceAvailability) {
        switch outcome {
        case .proposals(let proposals, let scope):
            drafts = proposals
            resultScope = scope
            phase = .proposals
        case .empty(let scope):
            resultScope = scope
            phase = .empty
        case .cancelled:
            phase = .request
        case .declined, .limitReached, .offline, .serviceUnavailable, .timedOut, .malformed, .tooLong, .failed:
            // Rate limits and connection failures move the store into a
            // persistent state that the calm state view explains better.
            phase = availability == .available ? .outcome(outcome) : .unavailable(availability)
        }
    }

    private func ask() {
        guard canAsk else {
            return
        }
        requestGeneration += 1
    }

    private func tryAgain() {
        requestGeneration += 1
    }

    private func switchMode() {
        switch activeMode {
        case .prompted:
            suggestsGroups = true
            requestGeneration += 1
        case .unprompted:
            suggestsGroups = false
            phase = .request
        }
    }

    private func editRequest() {
        phase = .request
    }

    private func requestLimitIncrease() {
        appModel.transcriptIntelligence.showQuotaLimitIncreaseSuggestion()
    }

    // MARK: - Proposals

    private func cancel() {
        if hasUnsavedProposals {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    /// Removing the last proposal leaves nothing to save or edit.
    private func returnToRequestIfEmptied(_ isEmpty: Bool) {
        if isEmpty, phase == .proposals {
            phase = .request
        }
    }

    private func showAddEpisodes(for draftID: UUID) {
        guard let show, let draft = drafts.first(where: { $0.id == draftID }) else {
            return
        }
        addEpisodesRequest = PlaylistProposalAddEpisodesRequest(
            draftID: draftID,
            query: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            excludedPositions: Set(draft.episodes.compactMap { show.positionsByEpisodeID[$0.episodeID] })
        )
    }

    private func appendEpisodes(_ episodes: [EpisodeListItemSnapshot], toDraftWithID draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else {
            return
        }
        let memberIDs = Set(drafts[index].episodes.map(\.episodeID))
        drafts[index].episodes += episodes.filter { !memberIDs.contains($0.episodeID) }
    }

    private func loadCatalog() async -> PlaylistOrganizerCatalog? {
        if let catalog {
            return catalog
        }
        guard let show else {
            return nil
        }
        do {
            let built = try await PlaylistOrganizerCatalog.build(episodes: show.episodes)
            catalog = built
            return built
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.error("Episode catalog build failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Save

    /// Saves every saveable proposal in order. A failure stops the loop,
    /// keeps the unsaved proposals on screen and explains on this sheet.
    private func save() {
        _ = appModel.playlists.consumeLastErrorMessage()
        var savedIDs = Set<UUID>()
        for draft in drafts where draft.isSaveable {
            if let failure = file(draft) {
                drafts.removeAll { savedIDs.contains($0.id) }
                errorMessage = failure
                return
            }
            savedIDs.insert(draft.id)
        }
        dismiss()
    }

    /// Creates one playlist and fills it; returns the failure to show. A
    /// playlist whose episodes could not be added is deleted again through
    /// the store, so no rollback failure reaches the root alert.
    private func file(_ draft: PlaylistProposalDraft) -> String? {
        let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let created = appModel.playlists.create(
            name: name,
            kind: .manual,
            origin: .ai,
            modelContext: modelContext
        ) else {
            return appModel.playlists.consumeLastErrorMessage() ?? "Unable to create the playlist."
        }
        let addedCount = appModel.playlists.add(draft.episodes, to: created.playlistID, modelContext: modelContext)
        guard addedCount == 0, let addFailure = appModel.playlists.consumeLastErrorMessage() else {
            return nil
        }
        appModel.playlists.delete(created.playlistID, modelContext: modelContext)
        guard let deleteFailure = appModel.playlists.consumeLastErrorMessage() else {
            return addFailure
        }
        return "\(addFailure)\n\(deleteFailure)"
    }
}
