import Foundation
import Observation
import SwiftData

/// Device-local download preferences: each show's Download New Episodes
/// opt-in and its watermark, each show's Keep Downloaded choice, and the
/// default limit, the Wi-Fi rule and the Downloads list grouping. Loads and
/// saves run in their own short-lived context, as in
/// `LibraryDisplaySettingsStore`, and published values change only after a
/// save succeeds. The store never trims or downloads; the app model acts
/// after a setter returns.
@Observable
final class DownloadSettingsStore {
    static let autoDownloadKeyPrefix = "downloads.autoDownloadNewEpisodes."
    static let autoDownloadWatermarkKeyPrefix = "downloads.autoDownloadWatermark."
    static let keepLimitKeyPrefix = "downloads.keepLimit."
    static let defaultKeepLimitPreferenceKey = "downloads.defaultKeepLimit"
    static let autoDownloadsWiFiOnlyPreferenceKey = "downloads.autoDownloadsWiFiOnly"
    static let listGroupingPreferenceKey = "downloads.listGrouping"
    private static let keyNamespace = "downloads."

    private(set) var autoDownloadPodcastIDs: Set<String> = []
    private(set) var defaultKeepLimit = DownloadKeepLimit.noLimit
    private(set) var autoDownloadsRequireWiFi = true
    private(set) var listGrouping = DownloadsListGrouping.flat
    private(set) var lastErrorMessage: String?
    private var keepLimitOverridesByPodcastID: [String: DownloadKeepLimit] = [:]
    // Read only by the automatic download pass, never by a view.
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

            var loadedAutoDownloadPodcastIDs: Set<String> = []
            var loadedWatermarks: [String: Date] = [:]
            var loadedOverrides: [String: DownloadKeepLimit] = [:]
            for (key, value) in valuesByKey {
                if let podcastID = Self.podcastID(in: key, prefix: Self.autoDownloadKeyPrefix) {
                    if value == "true" {
                        loadedAutoDownloadPodcastIDs.insert(podcastID)
                    }
                } else if let podcastID = Self.podcastID(in: key, prefix: Self.autoDownloadWatermarkKeyPrefix) {
                    loadedWatermarks[podcastID] = Self.decodeWatermark(value)
                } else if let podcastID = Self.podcastID(in: key, prefix: Self.keepLimitKeyPrefix) {
                    loadedOverrides[podcastID] = DownloadKeepLimit(rawValue: value)
                }
            }

            autoDownloadPodcastIDs = loadedAutoDownloadPodcastIDs
            watermarksByPodcastID = loadedWatermarks
            keepLimitOverridesByPodcastID = loadedOverrides
            defaultKeepLimit = valuesByKey[Self.defaultKeepLimitPreferenceKey]
                .flatMap(DownloadKeepLimit.init(rawValue:)) ?? .noLimit
            autoDownloadsRequireWiFi = valuesByKey[Self.autoDownloadsWiFiOnlyPreferenceKey]
                .flatMap(Bool.init) ?? true
            listGrouping = valuesByKey[Self.listGroupingPreferenceKey]
                .flatMap(DownloadsListGrouping.init(rawValue:)) ?? .flat
            lastErrorMessage = nil
        } catch {
            autoDownloadPodcastIDs = []
            watermarksByPodcastID = [:]
            keepLimitOverridesByPodcastID = [:]
            defaultKeepLimit = .noLimit
            autoDownloadsRequireWiFi = true
            listGrouping = .flat
            lastErrorMessage = "Unable to load download settings: \(error.localizedDescription)"
        }
    }

    func autoDownloadsNewEpisodes(forPodcastID podcastID: String) -> Bool {
        autoDownloadPodcastIDs.contains(podcastID)
    }

    /// Episodes released after this instant are the show's automatic
    /// download candidates. Nil while the show is off, or when its watermark
    /// row is missing.
    func autoDownloadWatermark(forPodcastID podcastID: String) -> Date? {
        watermarksByPodcastID[podcastID]
    }

    /// The show's own Keep Downloaded choice; nil follows the default.
    func keepLimitOverride(forPodcastID podcastID: String) -> DownloadKeepLimit? {
        keepLimitOverridesByPodcastID[podcastID]
    }

    func resolvedKeepLimit(forPodcastID podcastID: String) -> DownloadKeepLimit {
        keepLimitOverridesByPodcastID[podcastID] ?? defaultKeepLimit
    }

    /// Turning a show on writes its flag and, when given, its watermark in
    /// one save; turning it off deletes both rows.
    @discardableResult
    func setAutoDownloadsNewEpisodes(
        _ isEnabled: Bool,
        forPodcastID podcastID: String,
        watermark: Date? = nil,
        modelContext: ModelContext
    ) -> Bool {
        let flagKey = Self.autoDownloadKeyPrefix + podcastID
        let watermarkKey = Self.autoDownloadWatermarkKeyPrefix + podcastID
        let changes: [(key: String, value: String?)]
        if isEnabled {
            guard !autoDownloadsNewEpisodes(forPodcastID: podcastID)
                || (watermark != nil && watermark != watermarksByPodcastID[podcastID])
            else {
                return true
            }
            changes = [(flagKey, "true")] + (watermark.map { [(watermarkKey, Self.encodeWatermark($0))] } ?? [])
        } else {
            guard autoDownloadsNewEpisodes(forPodcastID: podcastID) || watermarksByPodcastID[podcastID] != nil else {
                return true
            }
            changes = [(flagKey, nil), (watermarkKey, nil)]
        }
        guard persist(
            changes,
            modelContext: modelContext,
            failureDescription: "Unable to update Download New Episodes"
        ) else {
            return false
        }

        if isEnabled {
            autoDownloadPodcastIDs.insert(podcastID)
            if let watermark {
                watermarksByPodcastID[podcastID] = watermark
            }
        } else {
            autoDownloadPodcastIDs.remove(podcastID)
            watermarksByPodcastID[podcastID] = nil
        }
        return true
    }

    /// Advances an enabled show's watermark. A failure is reported but
    /// leaves any user-facing message alone on success: a pass runs on its
    /// own, and must not clear an error the user has not read yet.
    @discardableResult
    func setAutoDownloadWatermark(
        _ watermark: Date,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard autoDownloadsNewEpisodes(forPodcastID: podcastID) else {
            return false
        }
        guard watermarksByPodcastID[podcastID] != watermark else {
            return true
        }
        guard persist(
            [(Self.autoDownloadWatermarkKeyPrefix + podcastID, Self.encodeWatermark(watermark))],
            modelContext: modelContext,
            failureDescription: "Unable to record new episodes for automatic download",
            clearsErrorOnSuccess: false
        ) else {
            return false
        }

        watermarksByPodcastID[podcastID] = watermark
        return true
    }

    /// Nil (Default) deletes the show's row, so an older duplicate can't
    /// resurface as the winner.
    @discardableResult
    func setKeepLimitOverride(
        _ keepLimit: DownloadKeepLimit?,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard keepLimitOverridesByPodcastID[podcastID] != keepLimit else {
            return true
        }
        guard persist(
            [(Self.keepLimitKeyPrefix + podcastID, keepLimit?.rawValue)],
            modelContext: modelContext,
            failureDescription: "Unable to update Keep Downloaded"
        ) else {
            return false
        }

        keepLimitOverridesByPodcastID[podcastID] = keepLimit
        return true
    }

    @discardableResult
    func setDefaultKeepLimit(_ keepLimit: DownloadKeepLimit, modelContext: ModelContext) -> Bool {
        guard defaultKeepLimit != keepLimit else {
            return true
        }
        guard persist(
            [(Self.defaultKeepLimitPreferenceKey, keepLimit.rawValue)],
            modelContext: modelContext,
            failureDescription: "Unable to update Keep Downloaded"
        ) else {
            return false
        }

        defaultKeepLimit = keepLimit
        return true
    }

    @discardableResult
    func setAutoDownloadsRequireWiFi(_ requiresWiFi: Bool, modelContext: ModelContext) -> Bool {
        guard autoDownloadsRequireWiFi != requiresWiFi else {
            return true
        }
        guard persist(
            [(Self.autoDownloadsWiFiOnlyPreferenceKey, String(requiresWiFi))],
            modelContext: modelContext,
            failureDescription: "Unable to update Wi-Fi Only"
        ) else {
            return false
        }

        autoDownloadsRequireWiFi = requiresWiFi
        return true
    }

    @discardableResult
    func setListGrouping(_ grouping: DownloadsListGrouping, modelContext: ModelContext) -> Bool {
        guard listGrouping != grouping else {
            return true
        }
        guard persist(
            [(Self.listGroupingPreferenceKey, grouping.rawValue)],
            modelContext: modelContext,
            failureDescription: "Unable to update Group by Show"
        ) else {
            return false
        }

        listGrouping = grouping
        return true
    }

    /// Deletes the show's opt-in, watermark and Keep Downloaded rows.
    @discardableResult
    func removePreferences(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        guard persist(
            [
                (Self.autoDownloadKeyPrefix + podcastID, nil),
                (Self.autoDownloadWatermarkKeyPrefix + podcastID, nil),
                (Self.keepLimitKeyPrefix + podcastID, nil),
            ],
            modelContext: modelContext,
            failureDescription: "Unable to remove this show's download settings"
        ) else {
            return false
        }

        autoDownloadPodcastIDs.remove(podcastID)
        watermarksByPodcastID[podcastID] = nil
        keepLimitOverridesByPodcastID[podcastID] = nil
        return true
    }

    /// Writes each value, or deletes every row for a key whose value is nil,
    /// in one save.
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
            try save(context)
            if clearsErrorOnSuccess {
                lastErrorMessage = nil
            }
            return true
        } catch {
            lastErrorMessage = "\(failureDescription): \(error.localizedDescription)"
            return false
        }
    }

    private static func podcastID(in key: String, prefix: String) -> String? {
        guard key.hasPrefix(prefix) else {
            return nil
        }
        let podcastID = String(key.dropFirst(prefix.count))
        return podcastID.isEmpty ? nil : podcastID
    }

    /// `Double.description` is the shortest text that parses back to the
    /// same value, so a watermark round-trips to the exact instant.
    private static func encodeWatermark(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate)
    }

    private static func decodeWatermark(_ value: String) -> Date? {
        Double(value).map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
