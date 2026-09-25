import Foundation
import Observation
import SwiftData

/// Device-local Inbox list preferences: the episode filter and whether
/// episodes in Up Next are hidden. Every load and save runs in its own
/// short-lived context, as in `LibraryDisplaySettingsStore`: a failed save
/// is discarded with that context instead of lingering as a dirty row, and
/// a preference save never flushes another context's pending synced edits.
/// Published values change only after a save succeeds.
@Observable
final class InboxEpisodeListSettingsStore {
    static let filterPreferenceKey = "inbox.filter"
    static let hidesQueuedEpisodesPreferenceKey = "inbox.hidesQueuedEpisodes"

    private(set) var filter = PodcastEpisodeFilter.all
    private(set) var hidesQueuedEpisodes = false
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
            lastErrorMessage = nil
        } catch {
            filter = .all
            hidesQueuedEpisodes = false
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

    private func persist(
        _ value: String,
        forKey key: String,
        modelContext: ModelContext,
        failureDescription: String
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(key: key, value: value, modelContext: context)
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
