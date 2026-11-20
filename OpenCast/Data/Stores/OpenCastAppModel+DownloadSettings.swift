import Foundation
import SwiftData

extension OpenCastAppModel {
    @discardableResult
    func setAutoDownloadsNewEpisodes(
        _ isEnabled: Bool,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard isEnabled else {
            return downloadSettings.setAutoDownloadsNewEpisodes(
                false,
                forPodcastID: podcastID,
                modelContext: modelContext
            )
        }
        return autoDownloads.enableAutoDownload(forPodcastID: podcastID, modelContext: modelContext)
    }

    @discardableResult
    func setDetectsAdsInNewEpisodes(
        _ isEnabled: Bool,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard isEnabled else {
            return downloadSettings.setDetectsAdsInNewEpisodes(
                false,
                forPodcastID: podcastID,
                modelContext: modelContext
            )
        }
        guard !downloadSettings.detectsAdsInNewEpisodes(forPodcastID: podcastID) else {
            return true
        }
        guard autoDownloads.enableAutoDownload(forPodcastID: podcastID, modelContext: modelContext),
              downloadSettings.setDetectsAdsInNewEpisodes(true, forPodcastID: podcastID, modelContext: modelContext)
        else {
            return false
        }
        newEpisodeAdDetection.enable(forPodcastID: podcastID, modelContext: modelContext)
        return true
    }

    @discardableResult
    func setKeepLimitOverride(
        _ keepLimit: DownloadKeepLimit?,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard downloadSettings.setKeepLimitOverride(keepLimit, forPodcastID: podcastID, modelContext: modelContext) else {
            return false
        }
        downloadCleanup.trimDownloadsToKeepLimit(forPodcastID: podcastID, modelContext: modelContext)
        return true
    }

    @discardableResult
    func setDefaultKeepLimit(_ keepLimit: DownloadKeepLimit, modelContext: ModelContext) -> Bool {
        guard downloadSettings.setDefaultKeepLimit(keepLimit, modelContext: modelContext) else {
            return false
        }
        downloadCleanup.trimAllDownloadsToKeepLimits(modelContext: modelContext)
        return true
    }

    @discardableResult
    func setAutoDownloadsRequireWiFi(_ requiresWiFi: Bool, modelContext: ModelContext) -> Bool {
        guard downloadSettings.setAutoDownloadsRequireWiFi(requiresWiFi, modelContext: modelContext) else {
            return false
        }
        if !requiresWiFi {
            autoDownloads.schedulePass(modelContext: modelContext)
        }
        return true
    }

    @discardableResult
    func setDownloadsListGrouping(_ grouping: DownloadsListGrouping, modelContext: ModelContext) -> Bool {
        downloadSettings.setListGrouping(grouping, modelContext: modelContext)
    }

    func scheduleAutoDownloadPass(modelContext: ModelContext) {
        autoDownloads.schedulePass(modelContext: modelContext)
    }

    func runAutoDownloadPass(modelContext: ModelContext) async {
        await autoDownloads.runPass(modelContext: modelContext)
    }

    func setAutoDownloadsScene(_ sceneID: UUID, isActive: Bool) {
        autoDownloads.setScene(sceneID, isActive: isActive)
        upNextAutoAdd.setScene(sceneID, isActive: isActive)
    }

    func removeAutoDownloadsScene(_ sceneID: UUID) {
        autoDownloads.removeScene(sceneID)
        upNextAutoAdd.removeScene(sceneID)
    }

    func trimDownloadsToKeepLimits(modelContext: ModelContext) {
        downloadCleanup.trimAllDownloadsToKeepLimits(modelContext: modelContext)
    }
}
