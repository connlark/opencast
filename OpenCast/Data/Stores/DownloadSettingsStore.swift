import Foundation
import Observation
import SwiftData

/// Device-local download preferences: each show's Download New Episodes
/// opt-in and its watermark, each show's Detect Ads in New Episodes opt-in
/// and the downloads it still owes a scan, each show's Keep Downloaded
/// choice, and the default limit, the Wi-Fi rule and the Downloads list
/// grouping. Loads and saves run in their own short-lived context, as in
/// `LibraryDisplaySettingsStore`, and published values change only after a
/// save succeeds. The store never trims, downloads or queues; the app model
/// acts after a setter returns.
@Observable
final class DownloadSettingsStore {
    static let autoDownloadKeyPrefix = "downloads.autoDownloadNewEpisodes."
    static let autoDownloadWatermarkKeyPrefix = "downloads.autoDownloadWatermark."
    static let keepLimitKeyPrefix = "downloads.keepLimit."
    static let detectAdsInNewEpisodesKeyPrefix = "downloads.detectAdsInNewEpisodes."
    /// One row per episode, keyed by episode ID, valued with its show's
    /// podcast ID.
    static let detectAdsPendingKeyPrefix = "downloads.detectAdsPending."
    static let defaultKeepLimitPreferenceKey = "downloads.defaultKeepLimit"
    static let autoDownloadsWiFiOnlyPreferenceKey = "downloads.autoDownloadsWiFiOnly"
    static let listGroupingPreferenceKey = "downloads.listGrouping"
    private static let keyNamespace = "downloads."

    private(set) var autoDownloadPodcastIDs: Set<String> = []
    private(set) var detectAdsPodcastIDs: Set<String> = []
    private(set) var defaultKeepLimit = DownloadKeepLimit.noLimit
    private(set) var autoDownloadsRequireWiFi = true
    private(set) var listGrouping = DownloadsListGrouping.flat
    private(set) var lastErrorMessage: String?
    private var keepLimitOverridesByPodcastID: [String: DownloadKeepLimit] = [:]
    // Read only by the automatic download pass, never by a view.
    @ObservationIgnored private var watermarksByPodcastID: [String: Date] = [:]
    // Read only by the new-episode ad detection trigger, never by a view.
    @ObservationIgnored private(set) var detectAdsPendingPodcastIDsByEpisodeID: [String: String] = [:]

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
            var loadedDetectAdsPodcastIDs: Set<String> = []
            var loadedPendingPodcastIDs: [String: String] = [:]
            for (key, value) in valuesByKey {
                if let podcastID = Self.identifier(in: key, prefix: Self.autoDownloadKeyPrefix) {
                    if value == "true" {
                        loadedAutoDownloadPodcastIDs.insert(podcastID)
                    }
                } else if let podcastID = Self.identifier(in: key, prefix: Self.autoDownloadWatermarkKeyPrefix) {
                    loadedWatermarks[podcastID] = Self.decodeWatermark(value)
                } else if let podcastID = Self.identifier(in: key, prefix: Self.keepLimitKeyPrefix) {
                    loadedOverrides[podcastID] = DownloadKeepLimit(rawValue: value)
                } else if let podcastID = Self.identifier(in: key, prefix: Self.detectAdsInNewEpisodesKeyPrefix) {
                    if value == "true" {
                        loadedDetectAdsPodcastIDs.insert(podcastID)
                    }
                } else if let episodeID = Self.identifier(in: key, prefix: Self.detectAdsPendingKeyPrefix),
                          !value.isEmpty {
                    loadedPendingPodcastIDs[episodeID] = value
                }
            }

            autoDownloadPodcastIDs = loadedAutoDownloadPodcastIDs
            watermarksByPodcastID = loadedWatermarks
            keepLimitOverridesByPodcastID = loadedOverrides
            detectAdsPodcastIDs = loadedDetectAdsPodcastIDs
            detectAdsPendingPodcastIDsByEpisodeID = loadedPendingPodcastIDs
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
            detectAdsPodcastIDs = []
            detectAdsPendingPodcastIDsByEpisodeID = [:]
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

    func detectsAdsInNewEpisodes(forPodcastID podcastID: String) -> Bool {
        detectAdsPodcastIDs.contains(podcastID)
    }

    /// The show of a download still owed an ad scan; nil when none is owed.
    func detectAdsPendingPodcastID(forEpisodeID episodeID: String) -> String? {
        detectAdsPendingPodcastIDsByEpisodeID[episodeID]
    }

    /// Turning a show on writes its flag and, when given, its watermark in
    /// one save; turning it off deletes both rows, and Detect Ads in New
    /// Episodes with the downloads it still owes a scan.
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
            guard autoDownloadsNewEpisodes(forPodcastID: podcastID)
                || watermarksByPodcastID[podcastID] != nil
                || hasDetectAdsRows(forPodcastID: podcastID)
            else {
                return true
            }
            changes = [(flagKey, nil), (watermarkKey, nil), (Self.detectAdsInNewEpisodesKeyPrefix + podcastID, nil)]
        }
        guard persist(
            changes,
            deletingPendingMarkersForPodcastID: isEnabled ? nil : loadedMarkersPodcastID(podcastID),
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
            forgetDetectAds(forPodcastID: podcastID)
        }
        return true
    }

    /// Detect Ads in New Episodes needs Download New Episodes: a show that
    /// is off can't turn it on. Turning it off deletes the flag and the
    /// show's pending markers in one save.
    @discardableResult
    func setDetectsAdsInNewEpisodes(
        _ isEnabled: Bool,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        if isEnabled {
            guard autoDownloadsNewEpisodes(forPodcastID: podcastID) else {
                return false
            }
            guard !detectsAdsInNewEpisodes(forPodcastID: podcastID) else {
                return true
            }
        } else {
            guard hasDetectAdsRows(forPodcastID: podcastID) else {
                return true
            }
        }
        guard persist(
            [(Self.detectAdsInNewEpisodesKeyPrefix + podcastID, isEnabled ? "true" : nil)],
            deletingPendingMarkersForPodcastID: isEnabled ? nil : loadedMarkersPodcastID(podcastID),
            modelContext: modelContext,
            failureDescription: "Unable to update Detect Ads in New Episodes"
        ) else {
            return false
        }

        if isEnabled {
            detectAdsPodcastIDs.insert(podcastID)
        } else {
            forgetDetectAds(forPodcastID: podcastID)
        }
        return true
    }

    /// Records downloads owed an ad scan, each with its show's podcast ID,
    /// keyed by episode ID. A show without Detect Ads in New Episodes gets
    /// no marker. Like a watermark, a marker is written while no one is
    /// looking, so a success leaves any unread message alone.
    @discardableResult
    func addDetectAdsPendingMarkers(
        _ podcastIDsByEpisodeID: [String: String],
        modelContext: ModelContext
    ) -> Bool {
        let added = podcastIDsByEpisodeID.filter { episodeID, podcastID in
            detectsAdsInNewEpisodes(forPodcastID: podcastID)
                && detectAdsPendingPodcastIDsByEpisodeID[episodeID] != podcastID
        }
        guard !added.isEmpty else {
            return true
        }
        guard persist(
            added.sorted { $0.key < $1.key }.map { (Self.detectAdsPendingKeyPrefix + $0.key, $0.value) },
            modelContext: modelContext,
            failureDescription: "Unable to record new episodes for ad detection",
            clearsErrorOnSuccess: false
        ) else {
            return false
        }

        detectAdsPendingPodcastIDsByEpisodeID.merge(added) { _, new in new }
        return true
    }

    /// Deletes the markers of these episodes in one save.
    @discardableResult
    func removeDetectAdsPendingMarkers(
        forEpisodeIDs episodeIDs: some Sequence<String>,
        modelContext: ModelContext
    ) -> Bool {
        let removed = Set(episodeIDs).filter { detectAdsPendingPodcastIDsByEpisodeID[$0] != nil }
        guard !removed.isEmpty else {
            return true
        }
        guard persist(
            removed.sorted().map { (Self.detectAdsPendingKeyPrefix + $0, nil) },
            modelContext: modelContext,
            failureDescription: "Unable to update new episodes for ad detection",
            clearsErrorOnSuccess: false
        ) else {
            return false
        }

        for episodeID in removed {
            detectAdsPendingPodcastIDsByEpisodeID[episodeID] = nil
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

    /// Deletes the show's opt-ins, watermark, Keep Downloaded and pending
    /// marker rows.
    @discardableResult
    func removePreferences(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        guard persist(
            [
                (Self.autoDownloadKeyPrefix + podcastID, nil),
                (Self.autoDownloadWatermarkKeyPrefix + podcastID, nil),
                (Self.keepLimitKeyPrefix + podcastID, nil),
                (Self.detectAdsInNewEpisodesKeyPrefix + podcastID, nil),
            ],
            deletingPendingMarkersForPodcastID: loadedMarkersPodcastID(podcastID),
            modelContext: modelContext,
            failureDescription: "Unable to remove this show's download settings"
        ) else {
            return false
        }

        autoDownloadPodcastIDs.remove(podcastID)
        watermarksByPodcastID[podcastID] = nil
        keepLimitOverridesByPodcastID[podcastID] = nil
        forgetDetectAds(forPodcastID: podcastID)
        return true
    }

    private func hasDetectAdsRows(forPodcastID podcastID: String) -> Bool {
        detectsAdsInNewEpisodes(forPodcastID: podcastID)
            || detectAdsPendingPodcastIDsByEpisodeID.values.contains(podcastID)
    }

    private func forgetDetectAds(forPodcastID podcastID: String) {
        detectAdsPodcastIDs.remove(podcastID)
        detectAdsPendingPodcastIDsByEpisodeID = detectAdsPendingPodcastIDsByEpisodeID.filter { $0.value != podcastID }
    }

    /// The show whose markers a save should delete: only one this store
    /// loaded a marker for, so a listener without markers pays no fetch.
    private func loadedMarkersPodcastID(_ podcastID: String) -> String? {
        detectAdsPendingPodcastIDsByEpisodeID.values.contains(podcastID) ? podcastID : nil
    }

    /// Writes each value, or deletes every row for a key whose value is nil,
    /// in one save. Given a show, its pending markers are found by their
    /// value and go too. A marker row this store never loaded is left to the
    /// new-episode trigger's sweep once a load reads it: the sweep drops one
    /// whose show no longer has the setting or whose download record is
    /// gone.
    private func persist(
        _ changes: [(key: String, value: String?)],
        deletingPendingMarkersForPodcastID markerPodcastID: String? = nil,
        modelContext: ModelContext,
        failureDescription: String,
        clearsErrorOnSuccess: Bool = true
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            if let markerPodcastID {
                let markerPrefix = Self.detectAdsPendingKeyPrefix
                let markers = try context.fetch(
                    FetchDescriptor<LocalPreferenceRecord>(
                        predicate: #Predicate { $0.key.starts(with: markerPrefix) && $0.value == markerPodcastID }
                    )
                )
                for marker in markers {
                    context.delete(marker)
                }
            }
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

    private static func identifier(in key: String, prefix: String) -> String? {
        guard key.hasPrefix(prefix) else {
            return nil
        }
        let identifier = String(key.dropFirst(prefix.count))
        return identifier.isEmpty ? nil : identifier
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
