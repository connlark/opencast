import Foundation
import Observation
import SwiftData

/// Device-local Inbox list preferences: the episode filter, whether
/// episodes in Up Next are hidden, and the Group by Podcast view with its
/// layout. Every load and save runs in its own short-lived context, as in
/// `LibraryDisplaySettingsStore`: a failed save is discarded with that
/// context instead of lingering as a dirty row, and a preference save never
/// flushes another context's pending synced edits. Published values change
/// only after a save succeeds.
@Observable
final class InboxEpisodeListSettingsStore {
    static let filterPreferenceKey = "inbox.filter"
    static let hidesQueuedEpisodesPreferenceKey = "inbox.hidesQueuedEpisodes"
    static let groupsByPodcastPreferenceKey = "inbox.groupsByPodcast"
    static let groupedLayoutPreferenceKey = "inbox.groupedLayout"

    private(set) var filter = PodcastEpisodeFilter.all
    private(set) var hidesQueuedEpisodes = false
    /// Shows the podcasts with matching episodes instead of the episodes.
    /// A view choice, not a filter: it hides nothing, so it stays out of
    /// `activeFilterTitles` and survives Show All Episodes.
    private(set) var groupsByPodcast = false
    private(set) var groupedLayout = LibraryLayoutPreference.automatic
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// The settings that differ from their defaults, in display order; empty
    /// while the Inbox shows everything.
    var activeFilterTitles: [String] {
        var titles: [String] = []
        if filter != .all {
            titles.append(filter.title)
        }
        if hidesQueuedEpisodes {
            titles.append("Up Next hidden")
        }
        return titles
    }

    /// `save` is the test seam for preference saves.
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
            lastErrorMessage = nil
        } catch {
            filter = .all
            hidesQueuedEpisodes = false
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

    /// Automatic is the absence of a choice, so selecting it deletes every
    /// row for the key, as `LibraryDisplaySettingsStore.setLayout` does.
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

    /// Persists the state represented by the filtered-empty action in one
    /// transaction, so a failed reset cannot leave one setting changed.
    @discardableResult
    func resetToDefaults(modelContext: ModelContext) -> Bool {
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
            lastErrorMessage = "Unable to reset Inbox settings: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes `value` for `key`, or deletes every row for `key` when nil.
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
