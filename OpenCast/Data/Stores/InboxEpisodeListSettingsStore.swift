import Foundation
import Observation
import SwiftData

/// Each load and save uses its own short-lived context: a failed save is discarded with it
/// instead of lingering as a dirty row, and never flushes another context's pending synced edits.
@Observable
final class InboxEpisodeListSettingsStore {
    static let filterPreferenceKey = "inbox.filter"
    static let hidesQueuedEpisodesPreferenceKey = "inbox.hidesQueuedEpisodes"
    static let groupsByPodcastPreferenceKey = "inbox.groupsByPodcast"
    static let groupedLayoutPreferenceKey = "inbox.groupedLayout"
    static let showsArchivedEpisodesPreferenceKey = "inbox.showsArchivedEpisodes"

    private(set) var filter = PodcastEpisodeFilter.all
    private(set) var hidesQueuedEpisodes = false
    private(set) var showsArchivedEpisodes = false
    /// A view choice, not a filter: it stays out of `activeFilterTitles` and survives a reset.
    private(set) var groupsByPodcast = false
    private(set) var groupedLayout = LibraryLayoutPreference.automatic
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    var activeFilterTitles: [String] {
        var titles: [String] = []
        if showsArchivedEpisodes {
            titles.append("Archived")
        }
        if filter != .all {
            titles.append(filter.title)
        }
        if hidesQueuedEpisodes {
            titles.append("Up Next hidden")
        }
        return titles
    }

    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            filter = try storedValue(forKey: Self.filterPreferenceKey, context: context)
                .flatMap(PodcastEpisodeFilter.init(rawValue:)) ?? .all
            hidesQueuedEpisodes = try storedValue(forKey: Self.hidesQueuedEpisodesPreferenceKey, context: context)
                .flatMap(Bool.init) ?? false
            groupsByPodcast = try storedValue(forKey: Self.groupsByPodcastPreferenceKey, context: context)
                .flatMap(Bool.init) ?? false
            groupedLayout = try storedValue(forKey: Self.groupedLayoutPreferenceKey, context: context)
                .flatMap(LibraryLayoutPreference.init(rawValue:)) ?? .automatic
            showsArchivedEpisodes = try storedValue(forKey: Self.showsArchivedEpisodesPreferenceKey, context: context)
                .flatMap(Bool.init) ?? false
            lastErrorMessage = nil
        } catch {
            filter = .all
            hidesQueuedEpisodes = false
            showsArchivedEpisodes = false
            groupsByPodcast = false
            groupedLayout = .automatic
            lastErrorMessage = "Unable to load Inbox settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setFilter(_ filter: PodcastEpisodeFilter, modelContext: ModelContext) -> Bool {
        guard self.filter != filter else {
            return true
        }
        guard persist(
            filter.rawValue,
            forKey: Self.filterPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Inbox filter"
        ) else {
            return false
        }

        self.filter = filter
        return true
    }

    @discardableResult
    func setHidesQueuedEpisodes(_ hidesQueuedEpisodes: Bool, modelContext: ModelContext) -> Bool {
        guard self.hidesQueuedEpisodes != hidesQueuedEpisodes else {
            return true
        }
        guard persist(
            String(hidesQueuedEpisodes),
            forKey: Self.hidesQueuedEpisodesPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Hide Up Next"
        ) else {
            return false
        }

        self.hidesQueuedEpisodes = hidesQueuedEpisodes
        return true
    }

    @discardableResult
    func setShowsArchivedEpisodes(_ showsArchivedEpisodes: Bool, modelContext: ModelContext) -> Bool {
        guard self.showsArchivedEpisodes != showsArchivedEpisodes else {
            return true
        }
        guard persist(
            String(showsArchivedEpisodes),
            forKey: Self.showsArchivedEpisodesPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Show Archived"
        ) else {
            return false
        }

        self.showsArchivedEpisodes = showsArchivedEpisodes
        return true
    }

    @discardableResult
    func setGroupsByPodcast(_ groupsByPodcast: Bool, modelContext: ModelContext) -> Bool {
        guard self.groupsByPodcast != groupsByPodcast else {
            return true
        }
        guard persist(
            String(groupsByPodcast),
            forKey: Self.groupsByPodcastPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Group by Podcast"
        ) else {
            return false
        }

        self.groupsByPodcast = groupsByPodcast
        return true
    }

    /// Automatic is the absence of a choice, so selecting it deletes the key's rows.
    @discardableResult
    func setGroupedLayout(_ layout: LibraryLayoutPreference, modelContext: ModelContext) -> Bool {
        guard groupedLayout != layout else {
            return true
        }
        guard persist(
            layout == .automatic ? nil : layout.rawValue,
            forKey: Self.groupedLayoutPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Inbox layout"
        ) else {
            return false
        }

        groupedLayout = layout
        return true
    }

    /// One transaction, so a failed save cannot leave one setting changed. The view choices
    /// (Show Archived, Group by Podcast) stay as they are.
    @discardableResult
    func resetFilterAndHideUpNext(modelContext: ModelContext) -> Bool {
        guard filter != .all || hidesQueuedEpisodes else {
            return true
        }

        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.filterPreferenceKey,
                value: PodcastEpisodeFilter.all.rawValue,
                modelContext: context
            )
            try LocalPreferenceRecord.upsert(
                key: Self.hidesQueuedEpisodesPreferenceKey,
                value: String(false),
                modelContext: context
            )
            try save(context)
            filter = .all
            hidesQueuedEpisodes = false
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to show all Inbox episodes: \(error.localizedDescription)"
            return false
        }
    }

    private func persist(
        _ value: String?,
        forKey key: String,
        modelContext: ModelContext,
        failureDescription: String
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            if let value {
                try LocalPreferenceRecord.upsert(key: key, value: value, modelContext: context)
            } else {
                try LocalPreferenceRecord.deletePreferences(forKey: key, modelContext: context)
            }
            try save(context)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "\(failureDescription): \(error.localizedDescription)"
            return false
        }
    }

    private func storedValue(forKey key: String, context: ModelContext) throws -> String? {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: context)?.value
    }
}
