import Foundation
import Observation
import SwiftData

/// The device-local half of Auto Add to Up Next: each show's release
/// watermark, the Auto Add Limit and the If Limit Reached rule. Whether a
/// show is on, and at which position, is the synced subscription value read
/// through `LibraryStore`, so nothing here gates on it. Loads and saves run
/// in their own short-lived context, as in `DownloadSettingsStore`, and
/// published values change only after a save succeeds. The store never
/// queues anything.
@Observable
final class UpNextAutoAddSettingsStore {
    static let watermarkKeyPrefix = "upNext.autoAddWatermark."
    static let limitPreferenceKey = "upNext.autoAddLimit"
    static let limitReachedActionPreferenceKey = "upNext.autoAddLimitReached"
    private static let keyNamespace = "upNext."

    private(set) var limit = UpNextAutoAddLimit.standard
    private(set) var limitReachedAction = UpNextAutoAddLimitReachedAction.stopAdding
    private(set) var lastErrorMessage: String?
    // Read only by the pass, never by a view.
    @ObservationIgnored private var watermarksByPodcastID: [String: Date] = [:]

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// `save` is the test seam for preference saves.
    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        let namespace = Self.keyNamespace
        do {
            let records = try context.fetch(
                FetchDescriptor<LocalPreferenceRecord>(
                    predicate: #Predicate { $0.key.starts(with: namespace) },
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                )
            )
            var valuesByKey: [String: String] = [:]
            for record in records where valuesByKey[record.key] == nil {
                valuesByKey[record.key] = record.value
            }

            var loadedWatermarks: [String: Date] = [:]
            for (key, value) in valuesByKey {
                if let podcastID = Self.podcastID(inWatermarkKey: key) {
                    loadedWatermarks[podcastID] = Self.decodeWatermark(value)
                }
            }

            watermarksByPodcastID = loadedWatermarks
            limit = valuesByKey[Self.limitPreferenceKey]
                .flatMap(Int.init)
                .flatMap(UpNextAutoAddLimit.init(rawValue:)) ?? .standard
            limitReachedAction = valuesByKey[Self.limitReachedActionPreferenceKey]
                .flatMap(UpNextAutoAddLimitReachedAction.init(rawValue:)) ?? .stopAdding
            lastErrorMessage = nil
        } catch {
            watermarksByPodcastID = [:]
            limit = .standard
            limitReachedAction = .stopAdding
            lastErrorMessage = "Unable to load Up Next settings: \(error.localizedDescription)"
        }
    }

    /// Episodes released after this instant are the show's candidates. Nil
    /// until the show is turned on on this device, or when its row is
    /// missing.
    func watermark(forPodcastID podcastID: String) -> Date? {
        watermarksByPodcastID[podcastID]
    }

    /// The shows with a loaded watermark; read only by the pass.
    var watermarkPodcastIDs: Set<String> {
        Set(watermarksByPodcastID.keys)
    }

    /// A failure is reported, but success leaves any user-facing message
    /// alone: a pass runs on its own and must not clear an error the user
    /// has not read yet.
    @discardableResult
    func setWatermark(
        _ watermark: Date,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard watermarksByPodcastID[podcastID] != watermark else {
            return true
        }
        guard persist(
            [(Self.watermarkKeyPrefix + podcastID, Self.encodeWatermark(watermark))],
            modelContext: modelContext,
            failureDescription: "Unable to record new episodes for Up Next",
            clearsErrorOnSuccess: false
        ) else {
            return false
        }

        watermarksByPodcastID[podcastID] = watermark
        return true
    }

    @discardableResult
    func removeWatermark(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        guard persist(
            [(Self.watermarkKeyPrefix + podcastID, nil)],
            modelContext: modelContext,
            failureDescription: "Unable to remove this show's Up Next settings"
        ) else {
            return false
        }

        watermarksByPodcastID[podcastID] = nil
        return true
    }

    /// Deletes every listed show's row in one save. As with `setWatermark`,
    /// success leaves an unread message alone: the pass calls it on its own.
    @discardableResult
    func removeWatermarks(forPodcastIDs podcastIDs: Set<String>, modelContext: ModelContext) -> Bool {
        guard !podcastIDs.isEmpty else {
            return true
        }
        guard persist(
            podcastIDs.sorted().map { (key: Self.watermarkKeyPrefix + $0, value: nil as String?) },
            modelContext: modelContext,
            failureDescription: "Unable to remove old Up Next settings",
            clearsErrorOnSuccess: false
        ) else {
            return false
        }

        for podcastID in podcastIDs {
            watermarksByPodcastID[podcastID] = nil
        }
        return true
    }

    @discardableResult
    func setLimit(_ limit: UpNextAutoAddLimit, modelContext: ModelContext) -> Bool {
        guard self.limit != limit else {
            return true
        }
        guard persist(
            [(Self.limitPreferenceKey, String(limit.rawValue))],
            modelContext: modelContext,
            failureDescription: "Unable to update Auto Add Limit"
        ) else {
            return false
        }

        self.limit = limit
        return true
    }

    @discardableResult
    func setLimitReachedAction(_ action: UpNextAutoAddLimitReachedAction, modelContext: ModelContext) -> Bool {
        guard limitReachedAction != action else {
            return true
        }
        guard persist(
            [(Self.limitReachedActionPreferenceKey, action.rawValue)],
            modelContext: modelContext,
            failureDescription: "Unable to update If Limit Reached"
        ) else {
            return false
        }

        limitReachedAction = action
        return true
    }

    /// `Double.description` is the shortest text that parses back to the
    /// same value, so a watermark round-trips to the exact instant.
    static func encodeWatermark(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate)
    }

    private static func decodeWatermark(_ value: String) -> Date? {
        Double(value).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func podcastID(inWatermarkKey key: String) -> String? {
        guard key.hasPrefix(watermarkKeyPrefix) else {
            return nil
        }
        let podcastID = String(key.dropFirst(watermarkKeyPrefix.count))
        return podcastID.isEmpty ? nil : podcastID
    }

    /// Writes each value, or deletes every row for a key whose value is nil,
    /// in one save. With nothing to delete or write there is no save, so
    /// removing a row that is not there succeeds even when saves fail.
    private func persist(
        _ changes: [(key: String, value: String?)],
        modelContext: ModelContext,
        failureDescription: String,
        clearsErrorOnSuccess: Bool = true
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            for change in changes {
                if let value = change.value {
                    try LocalPreferenceRecord.upsert(key: change.key, value: value, modelContext: context)
                } else {
                    try LocalPreferenceRecord.deletePreferences(forKey: change.key, modelContext: context)
                }
            }
            if context.hasChanges {
                try save(context)
            }
            if clearsErrorOnSuccess {
                lastErrorMessage = nil
            }
            return true
        } catch {
            lastErrorMessage = "\(failureDescription): \(error.localizedDescription)"
            return false
        }
    }
}
