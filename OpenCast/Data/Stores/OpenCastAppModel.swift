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
    let podcastDiscoveryService: any PodcastDiscoveryService
    let syncStatus: SyncStatusStore
    let allowsAutomaticFeedRefresh: Bool
    var nowPlayingPresentationRequest = 0
    var isNowPlayingPresented = false
    var onboardingPresentationRequest = 0
    var lastPlaybackError: String?
    #if DEBUG
    var lastVoiceBoostDeviceProbeResult: String?
    var lastVoiceBoostDeviceProbeReportStatus: String?
    var lastVoiceBoostDeviceProbeApplicationState: String?
    #endif
    @ObservationIgnored private var hasRunVoiceBoostDeviceProbe = false
    @ObservationIgnored private var pendingAutoplayEpisodeID: EpisodeID?

    init(
        cacheController: OpenCastCacheController = OpenCastCacheController(),
        httpClient: (any OpenCastHTTPClient)? = nil,
        library: LibraryStore? = nil,
        downloads: DownloadStore = DownloadStore(),
        playback: AVFoundationPlaybackController? = nil,
        appearanceSettings: AppearanceSettingsStore = AppearanceSettingsStore(),
        playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore(),
        onboardingState: OnboardingStateStore = OnboardingStateStore(),
        voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics? = nil,
        exposesVoiceBoostDiagnosticsStatus: Bool = false,
        runsVoiceBoostDeviceProbe: Bool = false,
        podcastDirectoryService: (any PodcastDirectoryService)? = nil,
        podcastDiscoveryService: (any PodcastDiscoveryService)? = nil,
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
            feedService: DefaultFeedService(httpClient: resolvedHTTPClient)
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
        if let podcastDiscoveryService {
            self.podcastDiscoveryService = podcastDiscoveryService
        } else if podcastDirectoryService == nil {
            self.podcastDiscoveryService = defaultPodcastDirectoryService
        } else {
            self.podcastDiscoveryService = EmptyPodcastDiscoveryService()
        }
        self.syncStatus = syncStatus
        self.allowsAutomaticFeedRefresh = allowsAutomaticFeedRefresh
    }

    func requestEpisodeAutoplayOnOpen(episodeID: String) {
        pendingAutoplayEpisodeID = EpisodeID(rawValue: episodeID)
    }

    func requestEpisodeAutoplayOnOpenIfNotListening(episodeID: String) {
        guard !isActivelyListening else {
            pendingAutoplayEpisodeID = nil
            return
        }

        requestEpisodeAutoplayOnOpen(episodeID: episodeID)
    }

    func consumeEpisodeAutoplayOnOpen(episodeID: String) -> Bool {
        let requestedEpisodeID = EpisodeID(rawValue: episodeID)
        defer {
            pendingAutoplayEpisodeID = nil
        }

        return pendingAutoplayEpisodeID == requestedEpisodeID
    }

    func playEpisode(_ record: EpisodeCacheRecord, modelContext: ModelContext) throws {
        try play(record, source: .stream, modelContext: modelContext)
    }

    func playDownloadedEpisode(
        _ record: EpisodeCacheRecord,
        downloadRecord: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws {
        try play(record, source: .downloaded(downloadRecord), modelContext: modelContext)
    }

    func unsubscribe(feedURL: String, modelContext: ModelContext) {
        let podcastID = PodcastID(rawValue: feedURL)
        if playback.currentEpisode?.podcastID == podcastID {
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
        }

        library.unsubscribe(feedURL: feedURL, modelContext: modelContext, downloadStore: downloads)
    }

    func resolvedPlaybackEpisode(
        for record: EpisodeCacheRecord,
        source: EpisodePlaybackSource = .stream,
        modelContext: ModelContext
    ) throws -> Episode {
        var episode = library.domainEpisode(for: record)

        switch source {
        case .stream:
            guard episode.audioURL != nil else {
                throw OpenCastCoreError.missingAudioURL
            }
        case .downloaded(let downloadRecord):
            guard downloadRecord.episodeID == record.episodeID,
                  downloadRecord.podcastID == record.podcastID
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

    @discardableResult
    func markEpisodePlayed(
        _ record: EpisodeCacheRecord,
        modelContext: ModelContext
    ) -> Bool {
        let didSave = library.markEpisodePlayed(record, modelContext: modelContext)
        if isCurrentEpisode(record) {
            // Mark Played is a playback command too, so unload even when persistence was already complete.
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
        }
        return didSave
    }

    @discardableResult
    func clearEpisodeProgress(
        _ record: EpisodeCacheRecord,
        modelContext: ModelContext
    ) -> Bool {
        let didClear = library.clearProgress(for: record, modelContext: modelContext)
        guard didClear else {
            return false
        }

        if isCurrentEpisode(record) {
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

    private func play(
        _ record: EpisodeCacheRecord,
        source: EpisodePlaybackSource,
        modelContext: ModelContext
    ) throws {
        flushPlaybackProgress(modelContext: modelContext)
        let episode = try resolvedPlaybackEpisode(for: record, source: source, modelContext: modelContext)
        applyVoiceBoostSetting(for: episode, modelContext: modelContext)
        try playback.load(episode, startPosition: library.resumePosition(for: record.episodeID))
        rememberLastPlaybackEpisode(record.episodeID, modelContext: modelContext)
        playback.play()
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

    private func isCurrentEpisode(_ record: EpisodeCacheRecord) -> Bool {
        playback.currentEpisode?.id.rawValue == record.episodeID
    }

    private var isActivelyListening: Bool {
        switch playback.state {
        case .loading, .buffering, .playing:
            true
        case .idle, .paused, .failed:
            false
        }
    }

    private func restorableEpisode(modelContext: ModelContext) -> EpisodeCacheRecord? {
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
