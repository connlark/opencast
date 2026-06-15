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
    public private(set) var playbackDiagnosticsText = ""

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
    @ObservationIgnored private var audioSessionMediaServicesResetObserver: NSObjectProtocol?
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
    @ObservationIgnored private var playbackPositionProtection = PlaybackPositionProtection()
    @ObservationIgnored private var playbackFailureRecoveryPolicy = PlaybackFailureRecoveryPolicy()
    @ObservationIgnored private var isPlaybackDiagnosticsEnabled = false
    @ObservationIgnored private var playbackDiagnosticsEvents: [String] = []

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
        playbackFailureRecoveryPolicy.reset()

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
            seekPlayer(to: snapshot.position, mode: .restoredPosition)
        }

        snapshot.state = .paused
        recordDiagnosticsEvent("loaded episode start=\(diagnosticsTime(snapshot.position)) url=\(audioURL.absoluteString)")
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

    public func setPlaybackDiagnosticsEnabled(_ isEnabled: Bool) {
        guard isPlaybackDiagnosticsEnabled != isEnabled else {
            return
        }

        isPlaybackDiagnosticsEnabled = isEnabled
        if isEnabled {
            refreshPlaybackDiagnosticsText()
        } else if !playbackDiagnosticsText.isEmpty {
            playbackDiagnosticsText = ""
        }
    }

    public func play() {
        play(source: "api")
    }

    private func play(source: String) {
        guard snapshot.currentEpisode != nil else {
            return
        }

        if !isPlaybackRequested {
            playbackFailureRecoveryPolicy.reset()
        }
        recordDiagnosticsEvent("play requested source=\(source)")
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
        pause(reason: "api")
    }

    private func pause(reason: String) {
        isPlaybackRequested = false
        player.pause()
        snapshot.state = snapshot.currentEpisode == nil ? .idle : .paused
        markProgressBoundary()
        recordDiagnosticsEvent("paused reason=\(reason) at \(diagnosticsTime(snapshot.position))")
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
        playbackPositionProtection.clear()
        recordDiagnosticsEvent("unloaded playback")
        replaceSnapshot(PlaybackSnapshot(rate: snapshot.rate, progressBoundaryID: snapshot.progressBoundaryID))
        nowPlayingPublisher.clear()
        remoteCommandController.updateAvailability(for: snapshot, resolvedDuration: nil)
        deactivateAudioSession()
    }

    public func togglePlayPause() {
        togglePlayPause(source: "api")
    }

    private func togglePlayPause(source: String) {
        recordDiagnosticsEvent("toggle play/pause source=\(source) state=\(snapshot.state.accessibilityDescription)")
        switch snapshot.state {
        case .playing, .buffering:
            pause(reason: "toggle \(source)")
        default:
            play(source: "toggle \(source)")
        }
    }

    public func seek(to position: TimeInterval) {
        guard snapshot.currentEpisode != nil, position.isFinite else {
            return
        }

        let clamped = clampedPosition(position)
        currentVoiceBoostTap?.reset()
        seekPlayer(to: clamped)
        snapshot.position = clamped
        markProgressBoundary()
        recordDiagnosticsEvent("seek requested position=\(diagnosticsTime(clamped))")
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

            self?.pause(reason: "sleep timer")
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
                guard shouldAcceptObservedPosition(newPosition) else {
                    if durationChanged {
                        publishPlaybackState()
                    }
                    return
                }

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
                self?.play(source: "remote play command")
            },
            pause: { [weak self] in
                self?.pause(reason: "remote pause command")
            },
            togglePlayPause: { [weak self] in
                self?.togglePlayPause(source: "remote toggle command")
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

        audioSessionMediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionMediaServicesWereReset()
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
        if let audioSessionMediaServicesResetObserver {
            NotificationCenter.default.removeObserver(audioSessionMediaServicesResetObserver)
            self.audioSessionMediaServicesResetObserver = nil
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

    private func handleAudioSessionMediaServicesWereReset() {
        isAudioSessionActive = false
        recordDiagnosticsEvent("audio session media services reset")

        guard isPlaybackRequested, snapshot.currentEpisode != nil else {
            return
        }

        play(source: "audio session media services reset")
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

        play(source: "audio session interruption ended")
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
        playbackPositionProtection.clear()
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
            transitionToBuffering(reason: "player waiting reason=\(player.reasonForWaitingToPlay?.rawValue ?? "nil")")
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
                transitionToBuffering(reason: "item status unknown")
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
            handleFailedCurrentItem(playerItem)
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
            transitionToBuffering(reason: "item playback buffer empty")
        } else if playerItem.isPlaybackLikelyToKeepUp {
            requestPlaybackForReadyItem(playerItem)
        }
    }

    private func handleCurrentItemPlaybackStalled(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem, snapshot.currentEpisode != nil else {
            return
        }

        if isPlaybackRequested {
            recordDiagnosticsEvent("playback stalled at \(diagnosticsTime(snapshot.position))")
            transitionToBuffering(reason: "AVPlayerItemPlaybackStalled")
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
            handleFailedCurrentItem(playerItem)
        case .unknown:
            transitionToBuffering(reason: "request playback for unknown item")
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
        recordDiagnosticsEvent(
            "requested ready item playback result=\(snapshot.state.accessibilityDescription) timeControlStatus=\(diagnosticsTimeControlStatus) waitingReason=\(player.reasonForWaitingToPlay?.rawValue ?? "nil")"
        )
        publishPlaybackState()
    }

    private var needsCurrentItemRebuildForPlaybackRetry: Bool {
        guard snapshot.currentEpisode != nil else {
            return false
        }
        if case .failed = snapshot.state {
            return true
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
            seekPlayer(to: snapshot.position, mode: .restoredPosition)
        }

        snapshot.state = .loading
        recordDiagnosticsEvent("rebuilt player item for retry at \(diagnosticsTime(snapshot.position))")
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
            seekPlayer(to: snapshot.position, mode: .restoredPosition)
        }

        recordDiagnosticsEvent("falling back from streaming cache to direct AVPlayer item")
        if isPlaybackRequested {
            requestPlaybackForCurrentItem()
        } else {
            snapshot.state = .paused
            publishPlaybackState()
        }
        return true
    }

    private func handleFailedCurrentItem(_ playerItem: AVPlayerItem) {
        if fallbackFromStreamingCacheIfNeeded(failedItem: playerItem) {
            return
        }
        if recoverFromFailedCurrentItemIfNeeded(playerItem) {
            return
        }
        failPlayback(error: playerItem.error, failedItem: playerItem)
    }

    private func transitionToBuffering(reason: String) {
        guard snapshot.currentEpisode != nil, snapshot.state != .buffering else {
            return
        }

        snapshot.state = .buffering
        recordDiagnosticsEvent("buffering reason=\(reason)")
        publishPlaybackState()
    }

    private func recoverFromFailedCurrentItemIfNeeded(_ playerItem: AVPlayerItem) -> Bool {
        guard player.currentItem === playerItem,
              snapshot.currentEpisode != nil,
              isPlaybackRequested,
              playbackFailureRecoveryPolicy.shouldAttemptAutomaticRetry(
                error: playerItem.error,
                errorLog: playerItem.errorLog()
              )
        else {
            return false
        }

        recordFailedItemDiagnostics(playerItem, error: playerItem.error, prefix: "transient failure")
        recordDiagnosticsEvent(
            "automatic transient playback retry attempt=\(playbackFailureRecoveryPolicy.automaticTransientFailureRetryCount) at \(diagnosticsTime(snapshot.position))"
        )

        guard rebuildCurrentItemForPlaybackRetry() else {
            return true
        }

        requestPlaybackForCurrentItem()
        return true
    }

    private func failPlayback(error: (any Error)?, failedItem: AVPlayerItem? = nil) {
        recordFailedItemDiagnostics(failedItem, error: error, prefix: "terminal failure")
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
        let playerPosition = clampPlaybackPosition(player.currentTime().seconds, to: resolvedDuration())
        if playerPosition > snapshot.position {
            snapshot.position = playerPosition
        }
        snapshot.state = .failed(message)
        markProgressBoundary()
        recordDiagnosticsEvent("playback failed: \(message)")
        publishPlaybackState()
    }

    private func recordFailedItemDiagnostics(
        _ playerItem: AVPlayerItem?,
        error: (any Error)?,
        prefix: String
    ) {
        recordDiagnosticsEvent("\(prefix) error=\(AVFoundationPlaybackDiagnosticsFormatter.errorSummary(for: error))")
        if let event = playerItem?.errorLog()?.events.last {
            recordDiagnosticsEvent(
                "\(prefix) errorLog=\(AVFoundationPlaybackDiagnosticsFormatter.errorLogSummary(for: event))"
            )
        }
        if let event = playerItem?.accessLog()?.events.last {
            recordDiagnosticsEvent(
                "\(prefix) accessLog=\(AVFoundationPlaybackDiagnosticsFormatter.accessLogSummary(for: event))"
            )
        }
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

    private enum SeekMode {
        case userInitiated
        case restoredPosition
    }

    private func seekPlayer(to position: TimeInterval, mode: SeekMode = .userInitiated) {
        let clamped = clampedPosition(position)
        let protectedSeekGeneration = playbackPositionProtection.startSeek(to: clamped)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let completion: @Sendable (Bool) -> Void = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.completeProtectedSeek(generation: protectedSeekGeneration, finished: finished)
            }
        }

        switch mode {
        case .userInitiated:
            player.seek(to: time, completionHandler: completion)
        case .restoredPosition:
            player.seek(
                to: time,
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: completion
            )
        }
    }

    private func completeProtectedSeek(generation: Int?, finished: Bool) {
        guard let generation else {
            return
        }

        playbackPositionProtection.completeSeek(generation: generation, finished: finished)
        refreshPlaybackDiagnosticsText()
    }

    private func shouldAcceptObservedPosition(_ position: TimeInterval) -> Bool {
        if case .failed = snapshot.state {
            return false
        }

        return playbackPositionProtection.acceptsObservedPosition(position)
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
        refreshPlaybackDiagnosticsText()
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

    private func recordDiagnosticsEvent(_ event: String) {
        let timestamp = Date.now.formatted(.dateTime.hour().minute().second())
        playbackDiagnosticsEvents.append("[\(timestamp)] \(event)")
        if playbackDiagnosticsEvents.count > 80 {
            playbackDiagnosticsEvents.removeFirst(playbackDiagnosticsEvents.count - 80)
        }
    }

    private func refreshPlaybackDiagnosticsText() {
        guard isPlaybackDiagnosticsEnabled else {
            if !playbackDiagnosticsText.isEmpty {
                playbackDiagnosticsText = ""
            }
            return
        }

        let text = AVFoundationPlaybackDiagnosticsFormatter.text(
            snapshot: snapshot,
            player: player,
            item: player.currentItem,
            isPlaybackRequested: isPlaybackRequested,
            isAudioSessionActive: isAudioSessionActive,
            protectedPlaybackPosition: playbackPositionProtection.position,
            automaticTransientFailureRetryCount: playbackFailureRecoveryPolicy.automaticTransientFailureRetryCount,
            automaticTransientFailureRetryLimit: PlaybackFailureRecoveryPolicy.automaticTransientFailureRetryLimit,
            streamingAudioCacheConfiguration: streamingAudioCacheConfiguration,
            currentStreamingPlayerItem: currentStreamingPlayerItem,
            currentStreamingFallbackURL: currentStreamingFallbackURL,
            hasAttemptedStreamingCacheFallback: hasAttemptedStreamingCacheFallback,
            events: playbackDiagnosticsEvents
        )
        if playbackDiagnosticsText != text {
            playbackDiagnosticsText = text
        }
    }

    private func diagnosticsTime(_ value: TimeInterval?) -> String {
        AVFoundationPlaybackDiagnosticsFormatter.time(value)
    }

    private var diagnosticsTimeControlStatus: String {
        AVFoundationPlaybackDiagnosticsFormatter.timeControlStatus(player.timeControlStatus)
    }

    private func activateAudioSession() throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        guard !isAudioSessionActive else {
            return
        }

        do {
            try activateAudioSessionOnce(session)
            isAudioSessionActive = true
        } catch {
            isAudioSessionActive = false
            recordDiagnosticsEvent("audio session activation failed: \(error.localizedDescription)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            do {
                try activateAudioSessionOnce(session)
                isAudioSessionActive = true
                recordDiagnosticsEvent("audio session activated after retry")
            } catch {
                recordDiagnosticsEvent("audio session activation retry failed: \(error.localizedDescription)")
                throw error
            }
        }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func activateAudioSessionOnce(_ session: AVAudioSession) throws {
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try session.setActive(true)
    }
    #endif

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
