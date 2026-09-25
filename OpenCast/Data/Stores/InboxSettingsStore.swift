import Foundation
import Observation
import SwiftData

/// Device-local Inbox display preferences.
@Observable
final class InboxSettingsStore {
    static let hidesPlayedEpisodesPreferenceKey = "inbox.showsUnplayedOnly"
    static let hidesQueuedEpisodesPreferenceKey = "inbox.hidesQueuedEpisodes"

    private(set) var hidesPlayedEpisodes = false
    private(set) var hidesQueuedEpisodes = false
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            let storedValue = try LocalPreferenceRecord.preference(
                forKey: Self.hidesPlayedEpisodesPreferenceKey,
                modelContext: context
            )?.value
            hidesPlayedEpisodes = storedValue.flatMap(Bool.init) ?? false

            let storedHidesQueued = try LocalPreferenceRecord.preference(
                forKey: Self.hidesQueuedEpisodesPreferenceKey,
                modelContext: context
            )?.value
            hidesQueuedEpisodes = storedHidesQueued.flatMap(Bool.init) ?? false

            lastErrorMessage = nil
        } catch {
            hidesPlayedEpisodes = false
            hidesQueuedEpisodes = false
            lastErrorMessage = "Unable to load Inbox settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setShowsUnplayedOnly(_ showsUnplayedOnly: Bool, modelContext: ModelContext) -> Bool {
        guard self.hidesPlayedEpisodes != showsUnplayedOnly else {
            return true
        }

        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.hidesPlayedEpisodesPreferenceKey,
                value: String(showsUnplayedOnly),
                modelContext: context
            )
            try save(context)
            self.hidesPlayedEpisodes = showsUnplayedOnly
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to update Inbox filter: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setHidesQueuedEpisodes(_ hidesQueuedEpisodes: Bool, modelContext: ModelContext) -> Bool {
        guard self.hidesQueuedEpisodes != hidesQueuedEpisodes else {
            return true
        }

        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.hidesQueuedEpisodesPreferenceKey,
                value: String(hidesQueuedEpisodes),
                modelContext: context
            )
            try save(context)
            self.hidesQueuedEpisodes = hidesQueuedEpisodes
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to update Inbox filter: \(error.localizedDescription)"
            return false
        }
    }
}
