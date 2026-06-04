@preconcurrency import AVFoundation
import Foundation
import Observation
import OpenCastCore
import OpenCastVoiceBoost

typealias VoiceBoostAudioTapFactory = (
    VoiceBoostConfiguration,
    VoiceBoostAudioTapDiagnostics?
) throws -> VoiceBoostAudioTap

@Observable
public final class AVFoundationPlaybackController: PlaybackController {
    public private(set) var snapshot = PlaybackSnapshot()
    public private(set) var currentEpisode: Episode?
    public private(set) var state: PlaybackState = .idle
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var progress: Double = 0
    public private(set) var progressBoundaryID = 0
    public private(set) var rate: Float = 1
    public private(set) var sleepTimerEndsAt: Date?
    public private(set) var skipBackwardInterval: TimeInterval = PlaybackSkipInterval.backward
    public private(set) var skipForwardInterval: TimeInterval = PlaybackSkipInterval.forward

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let nowPlayingPublisher: NowPlayingInfoPublisher
    @ObservationIgnored private let remoteCommandController = RemoteCommandController()
    @ObservationIgnored private var timeObserver: PlayerTimeObserver?
    @ObservationIgnored private var currentItemEndObserver: NSObjectProtocol?
    @ObservationIgnored private var currentItemPlaybackStalledObserver: NSObjectProtocol?
    @ObservationIgnored private var currentItemDurationObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemLikelyToKeepUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemBufferEmptyObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerTimeControlStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var audioSessionInterruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var audioSessionRouteChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var currentVoiceBoostTap: VoiceBoostAudioTap?
    @ObservationIgnored private var voiceBoostTrackLoadTask: Task<Void, Never>?
    @ObservationIgnored private let voiceBoostTapDiagnostics: VoiceBoostAudioTapDiagnostics?
    @ObservationIgnored private let voiceBoostAudioTapFactory: VoiceBoostAudioTapFactory
    @ObservationIgnored private let streamingAudioCacheConfiguration: StreamingAudioCacheConfiguration
    @ObservationIgnored private let streamingAudioDiskCache: StreamingAudioDiskCache?
    @ObservationIgnored private let streamingAudioRangeFetcher: any StreamingAudioHTTPRangeFetching
    @ObservationIgnored private var currentStreamingResourceLoaderDelegate: StreamingAudioResourceLoaderDelegate?
    @ObservationIgnored private weak var currentStreamingPlayerItem: AVPlayerItem?
    @ObservationIgnored private var currentStreamingFallbackURL: URL?
    @ObservationIgnored private var hasAttemptedStreamingCacheFallback = false
    @ObservationIgnored private var voiceBoostConfiguration = VoiceBoostConfiguration.default
    @ObservationIgnored private var isAudioSessionActive = false
    @ObservationIgnored private var isPlaybackRequested = false
    @ObservationIgnored private var shouldResumeAfterInterruption = false
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?

    public convenience init(
        voiceBoostTapDiagnostics: VoiceBoostAudioTapDiagnostics? = nil,
        nowPlayingArtworkLoader: (any NowPlayingArtworkLoading)? = nil,
        streamingAudioCacheConfiguration: StreamingAudioCacheConfiguration = .disabled
    ) {
        self.init(
            voiceBoostTapDiagnostics: voiceBoostTapDiagnostics,
            nowPlayingArtworkLoader: nowPlayingArtworkLoader,
            streamingAudioCacheConfiguration: streamingAudioCacheConfiguration,
            voiceBoostAudioTapFactory: {
                try VoiceBoostAudioTap(configuration: $0, diagnostics: $1)
            }
        )
    }

    init(
        voiceBoostTapDiagnostics: VoiceBoostAudioTapDiagnostics?,
        nowPlayingArtworkLoader: (any NowPlayingArtworkLoading)? = nil,
        streamingAudioCacheConfiguration: StreamingAudioCacheConfiguration = .disabled,
        voiceBoostAudioTapFactory: @escaping VoiceBoostAudioTapFactory = {
            try VoiceBoostAudioTap(configuration: $0, diagnostics: $1)
        }
    ) {
        self.nowPlayingPublisher = NowPlayingInfoPublisher(
            artworkLoader: nowPlayingArtworkLoader ?? DefaultNowPlayingArtworkLoader()
        )
        self.voiceBoostTapDiagnostics = voiceBoostTapDiagnostics
        self.voiceBoostAudioTapFactory = voiceBoostAudioTapFactory
        self.streamingAudioCacheConfiguration = streamingAudioCacheConfiguration
        self.streamingAudioDiskCache = streamingAudioCacheConfiguration.directory.map {
            StreamingAudioDiskCache(directory: $0)
        }
        self.streamingAudioRangeFetcher = URLSessionStreamingAudioRangeFetcher()
        installPeriodicTimeObserver()
        observePlayerTimeControlStatus()
        installAudioSessionObservers()
        installRemoteCommands()
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver.token)
        }
        removeCurrentItemObservations()
        resetStreamingCachePlaybackState()
        playerTimeControlStatusObservation?.invalidate()
        removeAudioSessionObservers()
        voiceBoostTrackLoadTask?.cancel()
        sleepTimerTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentVoiceBoostTap = nil
        nowPlayingPublisher.clear()
        remoteCommandController.updateAvailability(for: PlaybackSnapshot(), resolvedDuration: nil)
        #if os(iOS) || os(tvOS) || os(visionOS)
        if isAudioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    public func load(_ episode: Episode, startPosition: TimeInterval = 0) throws {
        guard let audioURL = episode.audioURL else {
            throw OpenCastCoreError.missingAudioURL
        }

        removeCurrentItemObservations()
        resetStreamingCachePlaybackState()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        isPlaybackRequested = false

        let episodeDuration = finitePositive(episode.duration)
        let initialPosition = clampPlaybackPosition(startPosition, to: episodeDuration)
        replaceSnapshot(PlaybackSnapshot(
            state: .loading,
            currentEpisode: episode,
            position: initialPosition,
            duration: episodeDuration,
            rate: snapshot.rate,
            sleepTimerEndsAt: snapshot.sleepTimerEndsAt,
            progressBoundaryID: snapshot.progressBoundaryID
        ))

        let playerItem = makePlayerItem(for: episode, audioURL: audioURL)
        player.replaceCurrentItem(with: playerItem)
        observeCurrentItem(playerItem)

        if snapshot.position > 0 {
            player.seek(to: CMTime(seconds: snapshot.position, preferredTimescale: 600))
        }

        snapshot.state = .paused
        publishPlaybackState()
    }

    public func updateVoiceBoostConfiguration(_ configuration: VoiceBoostConfiguration) {
        voiceBoostConfiguration = configuration
        if !configuration.isEnabled {
            voiceBoostTrackLoadTask?.cancel()
            voiceBoostTrackLoadTask = nil
        }
        if let currentVoiceBoostTap {
            currentVoiceBoostTap.update(configuration: configuration)
        } else if configuration.isEnabled, let currentItem = player.currentItem {
            installVoiceBoostTap(on: currentItem)
            if let asset = currentItem.asset as? AVURLAsset {
                scheduleTrackBoundVoiceBoostTapInstall(for: currentItem, asset: asset)
            }
        }
    }

    public func setVoiceBoostEnabled(_ isEnabled: Bool) {
        var configuration = voiceBoostConfiguration
        configuration.isEnabled = isEnabled
        updateVoiceBoostConfiguration(configuration)
    }

    public func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        guard backward.isFinite, backward > 0, forward.isFinite, forward > 0 else {
            return
        }

        skipBackwardInterval = backward
        skipForwardInterval = forward
        remoteCommandController.setSkipIntervals(backward: backward, forward: forward)
    }

    public func play() {
        guard snapshot.currentEpisode != nil else {
            return
        }

        isPlaybackRequested = true
        if needsCurrentItemRebuildForPlaybackRetry,
           !rebuildCurrentItemForPlaybackRetry()
        {
            return
        }

        do {
            try activateAudioSession()
        } catch {
            failPlayback(message: "Unable to activate audio session: \(error.localizedDescription)")
            return
        }

        requestPlaybackForCurrentItem()
    }

    public func pause() {
        isPlaybackRequested = false
        player.pause()
        snapshot.state = snapshot.currentEpisode == nil ? .idle : .paused
        markProgressBoundary()
        publishPlaybackState()
    }

    public func unload() {
        if snapshot.currentEpisode != nil {
            markProgressBoundary()
        }
        isPlaybackRequested = false
        shouldResumeAfterInterruption = false
        removeCurrentItemObservations()
        resetStreamingCachePlaybackState()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentVoiceBoostTap = nil
        replaceSnapshot(PlaybackSnapshot(rate: snapshot.rate, progressBoundaryID: snapshot.progressBoundaryID))
        nowPlayingPublisher.clear()
        remoteCommandController.updateAvailability(for: snapshot, resolvedDuration: nil)
        deactivateAudioSession()
    }

    public func togglePlayPause() {
        switch snapshot.state {
        case .playing, .buffering:
            pause()
        default:
            play()
        }
    }

    public func seek(to position: TimeInterval) {
        guard snapshot.currentEpisode != nil, position.isFinite else {
            return
        }

        let clamped = clampedPosition(position)
        currentVoiceBoostTap?.reset()
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        snapshot.position = clamped
        markProgressBoundary()
        publishPlaybackState()
    }

    public func skip(by interval: TimeInterval) {
        seek(to: snapshot.position + interval)
    }

    public func setRate(_ rate: Float) {
        snapshot.rate = clampedPlaybackRate(rate)
        if isPlaybackRequested {
            player.rate = snapshot.rate
        }
        publishPlaybackState()
    }

    public func setSleepTimer(duration: TimeInterval?) {
        sleepTimerTask?.cancel()

        guard let duration, duration > 0 else {
            snapshot.sleepTimerEndsAt = nil
            syncObservableState()
            return
        }

        let endsAt = Date(timeIntervalSinceNow: duration)
        snapshot.sleepTimerEndsAt = endsAt
        syncObservableState()
        sleepTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            self?.pause()
            self?.clearSleepTimer()
        }
    }

    private func installPeriodicTimeObserver() {
        timeObserver = PlayerTimeObserver(token: player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                guard snapshot.currentEpisode != nil else {
                    return
                }

                let durationChanged = updateDuration(from: player.currentItem?.duration)
                let newPosition = clampPlaybackPosition(time.seconds, to: resolvedDuration())
                let positionChanged = snapshot.position != newPosition
                if positionChanged {
                    snapshot.position = newPosition
                }

                guard durationChanged || positionChanged else {
                    return
                }

                if durationChanged {
                    publishPlaybackState()
                } else {
                    syncObservableState()
                }
            }
        })
    }

    private func observePlayerTimeControlStatus() {
        playerTimeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handlePlayerTimeControlStatusChanged()
            }
        }
    }

    private func installRemoteCommands() {
        remoteCommandController.install(RemoteCommandHandlers(
            play: { [weak self] in
                self?.play()
            },
            pause: { [weak self] in
                self?.pause()
            },
            togglePlayPause: { [weak self] in
                self?.togglePlayPause()
            },
            skipForward: { [weak self] in
                self?.skipForward()
            },
            skipBackward: { [weak self] in
                self?.skipBackward()
            },
            seek: { [weak self] position in
                self?.seek(to: position)
            }
        ))
    }

    private func skipForward() {
        skip(by: skipForwardInterval)
    }

    private func skipBackward() {
        skip(by: -skipBackwardInterval)
    }

    private func installAudioSessionObservers() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        audioSessionInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }

        audioSessionRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioSessionRouteChange(rawReason: rawReason)
            }
        }
        #endif
    }

    private func removeAudioSessionObservers() {
        if let audioSessionInterruptionObserver {
            NotificationCenter.default.removeObserver(audioSessionInterruptionObserver)
            self.audioSessionInterruptionObserver = nil
        }
        if let audioSessionRouteChangeObserver {
            NotificationCenter.default.removeObserver(audioSessionRouteChangeObserver)
            self.audioSessionRouteChangeObserver = nil
        }
    }

    private func handleAudioSessionInterruption(rawType: UInt?, rawOptions: UInt?) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            handleAudioSessionInterruptionBegan()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            handleAudioSessionInterruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
        #endif
    }

    private func handleAudioSessionInterruptionBegan() {
        shouldResumeAfterInterruption = isPlaybackRequested && snapshot.state == .playing
        isPlaybackRequested = false
        player.pause()

        guard snapshot.currentEpisode != nil else {
            return
        }

        snapshot.state = .paused
        markProgressBoundary()
        publishPlaybackState()
    }

    private func handleAudioSessionInterruptionEnded(shouldResume: Bool) {
        defer {
            shouldResumeAfterInterruption = false
        }

        guard shouldResume, shouldResumeAfterInterruption, snapshot.currentEpisode != nil else {
            return
        }

        play()
    }

    private func handleAudioSessionRouteChange(rawReason: UInt?) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            if snapshot.currentEpisode != nil {
                markProgressBoundary()
                publishPlaybackState()
            }
        default:
            break
        }
        #endif
    }

    private func makePlayerItem(for episode: Episode, audioURL: URL) -> AVPlayerItem {
        guard StreamingAudioCachePolicy.isEligible(audioURL, configuration: streamingAudioCacheConfiguration),
              let cache = streamingAudioDiskCache
        else {
            return makeDirectPlayerItem(audioURL: audioURL)
        }

        let resourceLoaderDelegate = StreamingAudioResourceLoaderDelegate(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            originalURL: audioURL,
            cache: cache,
            fetcher: streamingAudioRangeFetcher,
            byteBudget: streamingAudioCacheConfiguration.byteBudget
        )
        let asset = AVURLAsset(url: StreamingAudioCacheURL.url(for: audioURL))
        resourceLoaderDelegate.install(on: asset)
        let playerItem = configuredPlayerItem(asset: asset)
        currentStreamingResourceLoaderDelegate = resourceLoaderDelegate
        currentStreamingPlayerItem = playerItem
        currentStreamingFallbackURL = audioURL
        hasAttemptedStreamingCacheFallback = false
        return playerItem
    }

    private func makeDirectPlayerItem(audioURL: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: audioURL)
        return configuredPlayerItem(asset: asset)
    }

    private func configuredPlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: asset)
        installVoiceBoostTap(on: playerItem)
        scheduleTrackBoundVoiceBoostTapInstall(for: playerItem, asset: asset)
        return playerItem
    }

    private func resetStreamingCachePlaybackState() {
        currentStreamingResourceLoaderDelegate?.cancelAll()
        currentStreamingResourceLoaderDelegate = nil
        currentStreamingPlayerItem = nil
        currentStreamingFallbackURL = nil
        hasAttemptedStreamingCacheFallback = false
    }

    private func scheduleTrackBoundVoiceBoostTapInstall(for playerItem: AVPlayerItem, asset: AVURLAsset) {
        voiceBoostTrackLoadTask?.cancel()
        guard voiceBoostConfiguration.isEnabled else {
            voiceBoostTrackLoadTask = nil
            return
        }

        voiceBoostTrackLoadTask = Task { @MainActor [weak self, weak playerItem] in
            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                // Track loading can resume after item/configuration changes; keep these guards beside the install.
                guard !Task.isCancelled,
                      let self,
                      let playerItem,
                      self.player.currentItem === playerItem,
                      voiceBoostConfiguration.isEnabled,
                      let audioTrack = audioTracks.first
                else {
                    return
                }

                installVoiceBoostTap(on: playerItem, audioTrack: audioTrack)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.voiceBoostTapDiagnostics?.recordTapInstallFailure(error)
            }
        }
    }

    private func installVoiceBoostTap(on playerItem: AVPlayerItem, audioTrack: AVAssetTrack? = nil) {
        currentVoiceBoostTap = nil
        guard voiceBoostConfiguration.isEnabled else {
            playerItem.audioMix = nil
            return
        }

        do {
            voiceBoostTapDiagnostics?.recordTapInstallAttempt()
            let tap = try voiceBoostAudioTapFactory(voiceBoostConfiguration, voiceBoostTapDiagnostics)
            voiceBoostTapDiagnostics?.recordTapInstallSuccess()
            let inputParameters = if let audioTrack {
                AVMutableAudioMixInputParameters(track: audioTrack)
            } else {
                AVMutableAudioMixInputParameters()
            }
            inputParameters.audioTapProcessor = tap.audioTapProcessor

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [inputParameters]
            playerItem.audioMix = audioMix
            currentVoiceBoostTap = tap
        } catch {
            if case VoiceBoostAudioTapError.creationFailed(let status) = error {
                voiceBoostTapDiagnostics?.recordTapCreationFailure(status: status)
            } else {
                voiceBoostTapDiagnostics?.recordTapCreationFailure(status: nil)
            }
            playerItem.audioMix = nil
            currentVoiceBoostTap = nil
        }
    }

    private func observeCurrentItem(_ playerItem: AVPlayerItem) {
        observeEnd(of: playerItem)
        observePlaybackStall(of: playerItem)
        observeDuration(of: playerItem)
        observeStatus(of: playerItem)
        observeBuffering(of: playerItem)
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        currentItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemDidPlayToEnd()
            }
        }
    }

    private func observePlaybackStall(of playerItem: AVPlayerItem) {
        currentItemPlaybackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemPlaybackStalled(playerItem)
            }
        }
    }

    private func observeDuration(of playerItem: AVPlayerItem) {
        currentItemDurationObservation = playerItem.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                if updateDuration(from: item.duration) {
                    publishPlaybackState()
                } else {
                    syncObservableState()
                }
            }
        }
    }

    private func observeStatus(of playerItem: AVPlayerItem) {
        currentItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemStatusChanged(item)
            }
        }
    }

    private func observeBuffering(of playerItem: AVPlayerItem) {
        currentItemLikelyToKeepUpObservation = playerItem.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemBufferingChanged(item)
            }
        }

        currentItemBufferEmptyObservation = playerItem.observe(
            \.isPlaybackBufferEmpty,
            options: [.new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemBufferingChanged(item)
            }
        }
    }

    private func removeCurrentItemObservations() {
        if let currentItemEndObserver {
            NotificationCenter.default.removeObserver(currentItemEndObserver)
            self.currentItemEndObserver = nil
        }
        if let currentItemPlaybackStalledObserver {
            NotificationCenter.default.removeObserver(currentItemPlaybackStalledObserver)
            self.currentItemPlaybackStalledObserver = nil
        }
        currentItemDurationObservation?.invalidate()
        currentItemDurationObservation = nil
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        currentItemLikelyToKeepUpObservation?.invalidate()
        currentItemLikelyToKeepUpObservation = nil
        currentItemBufferEmptyObservation?.invalidate()
        currentItemBufferEmptyObservation = nil
    }

    private func handlePlayerTimeControlStatusChanged() {
        guard snapshot.currentEpisode != nil, isPlaybackRequested else {
            return
        }

        switch player.timeControlStatus {
        case .playing:
            snapshot.state = .playing
            publishPlaybackState()
        case .waitingToPlayAtSpecifiedRate:
            transitionToBuffering()
        case .paused:
            break
        @unknown default:
            break
        }
    }

    private func handleCurrentItemStatusChanged(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem else {
            return
        }

        switch playerItem.status {
        case .unknown:
            if isPlaybackRequested {
                transitionToBuffering()
            }
        case .readyToPlay:
            if updateDuration(from: playerItem.duration) {
                publishPlaybackState()
            }
            if isPlaybackRequested {
                requestPlaybackForReadyItem(playerItem)
            } else if snapshot.state == .loading || snapshot.state == .buffering {
                snapshot.state = .paused
                publishPlaybackState()
            }
        case .failed:
            if fallbackFromStreamingCacheIfNeeded(failedItem: playerItem) {
                return
            }
            failPlayback(error: playerItem.error)
        @unknown default:
            failPlayback(message: "This episode could not be played.")
        }
    }

    private func handleCurrentItemBufferingChanged(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem,
              playerItem.status == .readyToPlay,
              isPlaybackRequested
        else {
            return
        }

        if playerItem.isPlaybackBufferEmpty {
            transitionToBuffering()
        } else if playerItem.isPlaybackLikelyToKeepUp {
            requestPlaybackForReadyItem(playerItem)
        }
    }

    private func handleCurrentItemPlaybackStalled(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem, snapshot.currentEpisode != nil else {
            return
        }

        if isPlaybackRequested {
            transitionToBuffering()
            player.playImmediately(atRate: snapshot.rate)
        }
    }

    private func requestPlaybackForCurrentItem() {
        guard let playerItem = player.currentItem else {
            failPlayback(message: "This episode could not be played.")
            return
        }

        switch playerItem.status {
        case .readyToPlay:
            requestPlaybackForReadyItem(playerItem)
        case .failed:
            if fallbackFromStreamingCacheIfNeeded(failedItem: playerItem) {
                return
            }
            failPlayback(error: playerItem.error)
        case .unknown:
            transitionToBuffering()
            player.rate = snapshot.rate
        @unknown default:
            failPlayback(message: "This episode could not be played.")
        }
    }

    private func requestPlaybackForReadyItem(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem, snapshot.currentEpisode != nil else {
            return
        }

        player.playImmediately(atRate: snapshot.rate)
        switch player.timeControlStatus {
        case .playing:
            snapshot.state = .playing
        case .waitingToPlayAtSpecifiedRate, .paused:
            snapshot.state = .buffering
        @unknown default:
            snapshot.state = .buffering
        }
        publishPlaybackState()
    }

    private var needsCurrentItemRebuildForPlaybackRetry: Bool {
        guard snapshot.currentEpisode != nil else {
            return false
        }
        guard let currentItem = player.currentItem else {
            return true
        }

        return currentItem.status == .failed
    }

    private func rebuildCurrentItemForPlaybackRetry() -> Bool {
        guard let episode = snapshot.currentEpisode,
              let audioURL = episode.audioURL
        else {
            failPlayback(message: "This episode could not be played.")
            return false
        }

        removeCurrentItemObservations()
        resetStreamingCachePlaybackState()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        currentVoiceBoostTap = nil
        player.pause()

        let retryItem = makePlayerItem(for: episode, audioURL: audioURL)
        player.replaceCurrentItem(with: retryItem)
        observeCurrentItem(retryItem)

        if snapshot.position > 0 {
            player.seek(to: CMTime(seconds: snapshot.position, preferredTimescale: 600))
        }

        snapshot.state = .loading
        publishPlaybackState()
        return true
    }

    private func fallbackFromStreamingCacheIfNeeded(failedItem: AVPlayerItem) -> Bool {
        guard currentStreamingPlayerItem === failedItem,
              !hasAttemptedStreamingCacheFallback,
              let fallbackURL = currentStreamingFallbackURL
        else {
            return false
        }

        hasAttemptedStreamingCacheFallback = true
        currentStreamingResourceLoaderDelegate?.cancelAll()
        currentStreamingResourceLoaderDelegate = nil
        currentStreamingPlayerItem = nil
        currentStreamingFallbackURL = nil
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        removeCurrentItemObservations()

        let fallbackItem = makeDirectPlayerItem(audioURL: fallbackURL)
        player.replaceCurrentItem(with: fallbackItem)
        observeCurrentItem(fallbackItem)

        if snapshot.position > 0 {
            player.seek(to: CMTime(seconds: snapshot.position, preferredTimescale: 600))
        }

        if isPlaybackRequested {
            requestPlaybackForCurrentItem()
        } else {
            snapshot.state = .paused
            publishPlaybackState()
        }
        return true
    }

    private func transitionToBuffering() {
        guard snapshot.currentEpisode != nil, snapshot.state != .buffering else {
            return
        }

        snapshot.state = .buffering
        publishPlaybackState()
    }

    private func failPlayback(error: (any Error)?) {
        let message = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            failPlayback(message: "This episode could not be played. \(message)")
        } else {
            failPlayback(message: "This episode could not be played.")
        }
    }

    private func failPlayback(message: String) {
        isPlaybackRequested = false
        player.pause()
        snapshot.state = .failed(message)
        markProgressBoundary()
        publishPlaybackState()
    }

    private func handleCurrentItemDidPlayToEnd() {
        currentStreamingResourceLoaderDelegate?.markCompleted()
        isPlaybackRequested = false
        if let duration = resolvedDuration() {
            snapshot.duration = duration
            snapshot.position = duration
        }
        player.pause()
        snapshot.state = snapshot.currentEpisode == nil ? .idle : .paused
        markProgressBoundary()
        publishPlaybackState()
    }

    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        clampPlaybackPosition(position, to: resolvedDuration())
    }

    private func resolvedDuration() -> TimeInterval? {
        snapshot.bestFiniteDuration(preferring: player.currentItem?.duration.seconds)
    }

    @discardableResult
    private func updateDuration(from time: CMTime?) -> Bool {
        guard let duration = finitePositive(time?.seconds) else {
            return false
        }

        var changed = false
        if snapshot.duration != duration {
            snapshot.duration = duration
            changed = true
        }

        let position = clampPlaybackPosition(snapshot.position, to: duration)
        if snapshot.position != position {
            snapshot.position = position
            changed = true
        }

        return changed
    }

    private func markProgressBoundary() {
        snapshot.progressBoundaryID += 1
    }

    private func replaceSnapshot(_ snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        syncObservableState()
    }

    private func syncObservableState() {
        setIfChanged(\.currentEpisode, to: snapshot.currentEpisode)
        setIfChanged(\.state, to: snapshot.state)
        setIfChanged(\.position, to: snapshot.position)
        setIfChanged(\.duration, to: snapshot.duration)
        let normalizedProgress = snapshot.normalizedProgress
        setIfChanged(\.progress, to: normalizedProgress)
        setIfChanged(\.progressBoundaryID, to: snapshot.progressBoundaryID)
        setIfChanged(\.rate, to: snapshot.rate)
        setIfChanged(\.sleepTimerEndsAt, to: snapshot.sleepTimerEndsAt)
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AVFoundationPlaybackController, Value>,
        to value: Value
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func clearSleepTimer() {
        snapshot.sleepTimerEndsAt = nil
        syncObservableState()
    }

    private func publishPlaybackState() {
        defer {
            syncObservableState()
        }

        guard snapshot.currentEpisode != nil else {
            nowPlayingPublisher.clear()
            remoteCommandController.updateAvailability(for: snapshot, resolvedDuration: nil)
            return
        }

        let duration = resolvedDuration()
        if let duration {
            snapshot.duration = duration
            snapshot.position = clampPlaybackPosition(snapshot.position, to: duration)
        } else if !snapshot.position.isFinite {
            snapshot.position = 0
        }

        nowPlayingPublisher.publish(snapshot, resolvedDuration: duration)
        remoteCommandController.updateAvailability(for: snapshot, resolvedDuration: duration)
    }

    private func activateAudioSession() throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try session.setActive(true)
        isAudioSessionActive = true
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard isAudioSessionActive else {
            return
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
        }
        #endif
    }
}
