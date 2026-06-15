import Foundation
import Observation
import OpenCastCore
import OpenCastPlayback
import SwiftData

@Observable
final class OpenCastAppModel {
    private static let lastPlaybackEpisodeIDKey = "playback.lastEpisodeID"

    let cacheController: OpenCastCacheController
    let httpClient: any OpenCastHTTPClient
    let library: LibraryStore
    let downloads: DownloadStore
    let playback: AVFoundationPlaybackController
    let appearanceSettings: AppearanceSettingsStore
    let playbackSettings: PlaybackSettingsStore
    let onboardingState: OnboardingStateStore
    let voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics?
    let exposesVoiceBoostDiagnosticsStatus: Bool
    let runsVoiceBoostDeviceProbe: Bool
    let podcastDirectoryService: any PodcastDirectoryService
    let syncStatus: SyncStatusStore
    let allowsAutomaticFeedRefresh: Bool
    var nowPlayingPresentationRequest = 0
    var isNowPlayingPresented = false
    var onboardingPresentationRequest = 0
    var lastPlaybackError: String?
    var replacesNowPlayingArtworkWithPlaybackDiagnostics = false {
        didSet {
            guard oldValue != replacesNowPlayingArtworkWithPlaybackDiagnostics else {
                return
            }
            playback.setPlaybackDiagnosticsEnabled(replacesNowPlayingArtworkWithPlaybackDiagnostics)
        }
    }
    var isNukingData = false
    var lastDataNukeErrorMessage: String?
    var dataNukeCompletionID = 0
    #if DEBUG
    var lastVoiceBoostDeviceProbeResult: String?
    var lastVoiceBoostDeviceProbeReportStatus: String?
    var lastVoiceBoostDeviceProbeApplicationState: String?
    #endif
    @ObservationIgnored private var hasRunVoiceBoostDeviceProbe = false

    init(
        cacheController: OpenCastCacheController = OpenCastCacheController(),
        httpClient: (any OpenCastHTTPClient)? = nil,
        library: LibraryStore? = nil,
        localLibraryCacheStore: (any LocalLibraryCacheStore)? = nil,
        downloads: DownloadStore = DownloadStore(),
        playback: AVFoundationPlaybackController? = nil,
        appearanceSettings: AppearanceSettingsStore = AppearanceSettingsStore(),
        playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore(),
        onboardingState: OnboardingStateStore = OnboardingStateStore(),
        voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics? = nil,
        exposesVoiceBoostDiagnosticsStatus: Bool = false,
        runsVoiceBoostDeviceProbe: Bool = false,
        podcastDirectoryService: (any PodcastDirectoryService)? = nil,
        syncStatus: SyncStatusStore = SyncStatusStore(),
        allowsAutomaticFeedRefresh: Bool = true
    ) {
        let resolvedHTTPClient = httpClient ?? URLSessionOpenCastHTTPClient(
            configuration: OpenCastURLSessionFactory.sharedConfiguration(
                cacheDirectory: cacheController.httpCacheDirectory
            )
        )

        self.cacheController = cacheController
        self.httpClient = resolvedHTTPClient
        self.library = library ?? LibraryStore(
            feedService: DefaultFeedService(httpClient: resolvedHTTPClient),
            localCache: localLibraryCacheStore ?? SQLiteLocalLibraryCacheStore(
                databaseURL: SQLiteLocalLibraryCacheStore.defaultDatabaseURL()
            )
        )
        self.downloads = downloads
        self.playback = playback ?? AVFoundationPlaybackController(
            nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
        )
        self.appearanceSettings = appearanceSettings
        self.playbackSettings = playbackSettings
        self.onboardingState = onboardingState
        self.voiceBoostDiagnostics = voiceBoostDiagnostics
        self.exposesVoiceBoostDiagnosticsStatus = exposesVoiceBoostDiagnosticsStatus
        self.runsVoiceBoostDeviceProbe = runsVoiceBoostDeviceProbe
        let defaultPodcastDirectoryService = ITunesPodcastDirectoryService(httpClient: resolvedHTTPClient)
        let resolvedPodcastDirectoryService = podcastDirectoryService ?? defaultPodcastDirectoryService
        self.podcastDirectoryService = resolvedPodcastDirectoryService
        self.syncStatus = syncStatus
        self.allowsAutomaticFeedRefresh = allowsAutomaticFeedRefresh
    }

    func playEpisode(_ episode: EpisodeListItemSnapshot, modelContext: ModelContext) throws {
        try play(episode, source: .stream, modelContext: modelContext)
    }

    func playDownloadedEpisode(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws {
        try play(episode, source: .downloaded(downloadRecord), modelContext: modelContext)
    }

    func unsubscribe(feedURL: String, modelContext: ModelContext) async {
        let podcastID = PodcastID(rawValue: feedURL)
        if playback.currentEpisode?.podcastID == podcastID {
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
        }

        await library.unsubscribe(feedURL: feedURL, modelContext: modelContext, downloadStore: downloads)
    }

    func resolvedPlaybackEpisode(
        for snapshot: EpisodeListItemSnapshot,
        source: EpisodePlaybackSource = .stream,
        modelContext: ModelContext
    ) throws -> Episode {
        var episode = library.domainEpisode(for: snapshot)

        switch source {
        case .stream:
            guard episode.audioURL != nil else {
                throw OpenCastCoreError.missingAudioURL
            }
        case .downloaded(let downloadRecord):
            guard downloadRecord.episodeID == snapshot.episodeID,
                  downloadRecord.podcastID == snapshot.podcastID
            else {
                throw EpisodeDownloadError.invalidDownloadedRecord
            }
            guard downloadRecord.state == .completed else {
                throw EpisodeDownloadError.downloadNotComplete
            }
            guard let localFileURL = downloads.localFileURL(for: downloadRecord),
                  downloads.downloadedFileExists(for: downloadRecord)
            else {
                try downloads.markDownloadedFileMissing(downloadRecord, modelContext: modelContext)
                throw EpisodeDownloadError.missingDownloadedFile
            }
            episode.audioURL = localFileURL
        }

        return episode
    }

    @discardableResult
    func flushPlaybackProgress(
        modelContext: ModelContext,
        refreshObservableProgress: Bool = true
    ) -> Bool {
        guard let episode = playback.currentEpisode else {
            return false
        }

        let duration = sanitizedDuration(playback.duration ?? episode.duration)
        let position = sanitizedPosition(playback.position, duration: duration)
        let didSave = library.updateProgress(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            position: position,
            duration: duration,
            modelContext: modelContext,
            refreshObservableProgress: refreshObservableProgress
        )
        if LibraryStore.isPlayed(position: position, duration: duration) {
            clearLastPlaybackEpisode(modelContext: modelContext)
        } else {
            rememberLastPlaybackEpisode(episode.id.rawValue, modelContext: modelContext)
        }
        return didSave
    }

    func restorePreviousPlaybackIfAvailable(modelContext: ModelContext) {
        guard playback.currentEpisode == nil else {
            return
        }

        guard let record = restorableEpisode(modelContext: modelContext) else {
            clearLastPlaybackEpisode(modelContext: modelContext)
            return
        }

        do {
            let episode = try resolvedPlaybackEpisode(for: record, modelContext: modelContext)
            applyVoiceBoostSetting(for: episode, modelContext: modelContext)
            try playback.load(episode, startPosition: library.resumePosition(for: record.episodeID))
            rememberLastPlaybackEpisode(record.episodeID, modelContext: modelContext)
        } catch {
            clearLastPlaybackEpisode(modelContext: modelContext)
        }
    }

    func requestNowPlayingPresentation() {
        nowPlayingPresentationRequest += 1
    }

    @discardableResult
    func dismissCurrentPlayback(modelContext: ModelContext) -> Bool {
        let hadCurrentEpisode = playback.currentEpisode != nil
        flushPlaybackProgress(modelContext: modelContext)
        playback.unload()
        clearLastPlaybackEpisode(modelContext: modelContext)
        isNowPlayingPresented = false
        return hadCurrentEpisode
    }

    func requestNowPlayingPresentationAfterPrewarm(for episodeID: EpisodeID) {
        Task { [weak self] in
            // Yield so SwiftUI can mount the hidden Now Playing overlay before presenting it.
            await Task.yield()
            guard self?.playback.currentEpisode?.id == episodeID else {
                return
            }

            self?.requestNowPlayingPresentation()
        }
    }

    func requestOnboardingPresentation() {
        onboardingPresentationRequest += 1
    }

    func refreshLibraryIfStale(modelContext: ModelContext) async {
        guard allowsAutomaticFeedRefresh else {
            return
        }

        await library.refreshAllIfStale(modelContext: modelContext)
    }

    func nukeAllData(modelContext: ModelContext) async throws {
        guard !isNukingData else {
            return
        }

        isNukingData = true
        lastDataNukeErrorMessage = nil
        defer {
            isNukingData = false
        }

        do {
            let accountStatus = await syncStatus.refreshAccountStatus(force: true)
            guard accountStatus == .available else {
                throw DataNukeError.iCloudUnavailable(accountStatus)
            }

            library.prepareForDataNuke()
            try downloads.nukeAllDownloads(modelContext: modelContext)
            try deleteAllModelRows(modelContext: modelContext)
            // Reset runtime state before any suspension so the UI never renders
            // the deleted-and-saved SwiftData records, even if a later step throws.
            resetRuntimeStateAfterDataNuke(modelContext: modelContext)
            try await library.deleteAllLocalCache()
            try await cacheController.clearCachesNow()
            dataNukeCompletionID += 1
        } catch {
            lastDataNukeErrorMessage = error.localizedDescription
            throw error
        }
    }

    func clearDataNukeError() {
        lastDataNukeErrorMessage = nil
    }

    @discardableResult
    func markEpisodePlayed(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let didSave = library.markEpisodePlayed(episode, modelContext: modelContext)
        if isCurrentEpisode(episode) {
            // Mark Played is a playback command too, so unload even when persistence was already complete.
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
        }
        return didSave
    }

    @discardableResult
    func clearEpisodeProgress(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let didClear = library.clearProgress(for: episode, modelContext: modelContext)
        guard didClear else {
            return false
        }

        if isCurrentEpisode(episode) {
            playback.seek(to: 0)
            clearLastPlaybackEpisode(modelContext: modelContext)
        }
        return true
    }

    func refreshCurrentVoiceBoostSetting(modelContext: ModelContext) {
        playbackSettings.load(
            episodeID: playback.currentEpisode?.id.rawValue,
            podcastID: playback.currentEpisode?.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setAppearanceMode(
        _ mode: AppAppearanceMode,
        modelContext: ModelContext
    ) -> Bool {
        appearanceSettings.setMode(mode, modelContext: modelContext)
    }

    @discardableResult
    func setVoiceBoostMode(
        _ mode: VoiceBoostMode,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setVoiceBoostMode(
            mode,
            episodeID: playback.currentEpisode?.id.rawValue,
            podcastID: playback.currentEpisode?.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setVoiceBoostEnabled(
        _ isEnabled: Bool,
        forEpisodeID episodeID: String,
        podcastID: String?,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setVoiceBoostEnabled(
            isEnabled,
            forEpisodeID: episodeID,
            podcastID: podcastID,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setSkipBackwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setSkipBackwardOption(
            option,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setSkipForwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setSkipForwardOption(
            option,
            modelContext: modelContext,
            playback: playback
        )
    }

    func runVoiceBoostDeviceProbeIfNeeded(modelContext: ModelContext) async {
        #if DEBUG
        guard runsVoiceBoostDeviceProbe, !hasRunVoiceBoostDeviceProbe else {
            return
        }

        hasRunVoiceBoostDeviceProbe = true
        await runVoiceBoostDeviceProbe(trigger: "launch", modelContext: modelContext)
        #endif
    }

    #if DEBUG
    func runVoiceBoostDeviceProbe(trigger: String, modelContext: ModelContext) async {
        let report = await VoiceBoostDeviceProbe().run(
            trigger: trigger,
            appModel: self,
            modelContext: modelContext
        )
        updateVoiceBoostDeviceProbeSummary(from: report)
    }

    func writeVoiceBoostDeviceProbeWaitingForActiveReportIfNeeded() {
        guard runsVoiceBoostDeviceProbe, !hasRunVoiceBoostDeviceProbe else {
            return
        }

        do {
            let report = try VoiceBoostDeviceProbe().writeWaitingForActiveReport(appModel: self)
            updateVoiceBoostDeviceProbeSummary(from: report)
        } catch {
            lastPlaybackError = "Unable to write Voice Boost device probe report: \(error.localizedDescription)"
            refreshVoiceBoostDeviceProbeReportStatus()
        }
    }

    private func updateVoiceBoostDeviceProbeSummary(from report: VoiceBoostDeviceProbeReport) {
        lastVoiceBoostDeviceProbeResult = "\(report.trigger): \(report.result)"
        lastVoiceBoostDeviceProbeApplicationState = "\(report.startedApplicationState) to \(report.finishedApplicationState)"
        refreshVoiceBoostDeviceProbeReportStatus()
    }

    private func refreshVoiceBoostDeviceProbeReportStatus() {
        lastVoiceBoostDeviceProbeReportStatus = FileManager.default.fileExists(atPath: VoiceBoostDeviceProbe.reportURL.path)
            ? "Report Written"
            : "Report Missing"
    }
    #endif

    private func deleteAllModelRows(modelContext: ModelContext) throws {
        try deleteAll(SubscriptionRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeProgressRecord.self, modelContext: modelContext)
        try deleteAll(PodcastCacheRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeCacheRecord.self, modelContext: modelContext)
        try deleteAll(RefreshLogRecord.self, modelContext: modelContext)
        try deleteAll(LocalPreferenceRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeDownloadRecord.self, modelContext: modelContext)
        try modelContext.save()
    }

    private func deleteAll<Model: PersistentModel>(
        _ modelType: Model.Type,
        modelContext: ModelContext
    ) throws {
        for record in try modelContext.fetch(FetchDescriptor<Model>()) {
            modelContext.delete(record)
        }
    }

    private func resetRuntimeStateAfterDataNuke(modelContext: ModelContext) {
        playback.unload()
        isNowPlayingPresented = false
        lastPlaybackError = nil
        library.resetAfterDataNuke()
        downloads.load(modelContext: modelContext)
        appearanceSettings.load(modelContext: modelContext)
        playbackSettings.load(modelContext: modelContext, playback: playback)
        onboardingState.load(modelContext: modelContext)
        #if DEBUG
        try? FileManager.default.removeItem(at: VoiceBoostDeviceProbe.reportURL)
        lastVoiceBoostDeviceProbeResult = nil
        lastVoiceBoostDeviceProbeApplicationState = nil
        refreshVoiceBoostDeviceProbeReportStatus()
        #endif
    }

    private func play(
        _ snapshot: EpisodeListItemSnapshot,
        source: EpisodePlaybackSource,
        modelContext: ModelContext
    ) throws {
        flushPlaybackProgress(modelContext: modelContext)
        let episode = try resolvedPlaybackEpisode(for: snapshot, source: source, modelContext: modelContext)
        nowPlayingProbeMark("play-validated")
        applyVoiceBoostSetting(for: episode, modelContext: modelContext)
        try playback.load(episode, startPosition: library.resumePosition(for: snapshot.episodeID))
        nowPlayingProbeMark("play-loaded")
        rememberLastPlaybackEpisode(snapshot.episodeID, modelContext: modelContext)
        playback.play()
        nowPlayingProbeMark("play-started")
        requestNowPlayingPresentationAfterPrewarm(for: episode.id)
    }

    private func applyVoiceBoostSetting(for episode: Episode, modelContext: ModelContext) {
        playbackSettings.load(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    private func isCurrentEpisode(_ episode: EpisodeListItemSnapshot) -> Bool {
        playback.currentEpisode?.id.rawValue == episode.episodeID
    }

    private func restorableEpisode(modelContext: ModelContext) -> EpisodeListItemSnapshot? {
        guard let episodeID = storedLastPlaybackEpisodeID(modelContext: modelContext),
              let episode = library.episode(with: episodeID),
              library.canRestorePlayback(for: episode)
        else {
            return nil
        }

        return episode
    }

    private func rememberLastPlaybackEpisode(_ episodeID: String, modelContext: ModelContext) {
        let record: LocalPreferenceRecord
        if let existingRecord = lastPlaybackEpisodePreference(modelContext: modelContext) {
            record = existingRecord
        } else {
            record = LocalPreferenceRecord(
                key: Self.lastPlaybackEpisodeIDKey,
                value: episodeID
            )
            modelContext.insert(record)
        }

        record.value = episodeID
        record.updatedAt = .now
        try? modelContext.save()
    }

    private func clearLastPlaybackEpisode(modelContext: ModelContext) {
        let records = lastPlaybackEpisodePreferences(modelContext: modelContext)
        guard !records.isEmpty else {
            return
        }

        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    private func storedLastPlaybackEpisodeID(modelContext: ModelContext) -> String? {
        lastPlaybackEpisodePreference(modelContext: modelContext)?.value.trimmedNonEmpty
    }

    private func lastPlaybackEpisodePreference(modelContext: ModelContext) -> LocalPreferenceRecord? {
        lastPlaybackEpisodePreferences(modelContext: modelContext).first
    }

    private func lastPlaybackEpisodePreferences(modelContext: ModelContext) -> [LocalPreferenceRecord] {
        let key = Self.lastPlaybackEpisodeIDKey
        let descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func sanitizedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = position.isFinite ? max(0, position) : 0
        guard let duration else {
            return lowerBounded
        }
        return min(lowerBounded, duration)
    }

    private func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }
}
