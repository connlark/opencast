@preconcurrency import AVFoundation
import Foundation
import Observation
import OpenCastCore
import OpenCastVoiceBoost
import os

typealias VoiceBoostAudioTapFactory = (
    VoiceBoostConfiguration,
    VoiceBoostAudioTapDiagnostics?
) throws -> VoiceBoostAudioTap

public typealias PlaybackRateChangeRequestHandler = @MainActor (Float) -> Void
public typealias PlaybackEpisodeFinishedHandler = @MainActor (Episode) -> Void
public typealias PlaybackNextTrackHandler = @MainActor () -> Void

@Observable
public final class AVFoundationPlaybackController {
    private static let autoSkipSettleTolerance: TimeInterval = 0.05
    private static let logger = Logger(
        subsystem: "OpenCastPlayback",
        category: "AVFoundationPlaybackController"
    )

    public private(set) var snapshot = PlaybackSnapshot()
    public private(set) var currentEpisode: Episode?
    public private(set) var state: PlaybackState = .idle
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var progress: Double = 0
    public private(set) var progressBoundaryID = 0
    public private(set) var rate: Float = 1
    public private(set) var sleepTimerEndsAt: Date?
    public private(set) var sleepTimerMode = PlaybackSleepTimerMode.off
    public private(set) var skipZones: [PlaybackSkipZone] = []
    public private(set) var lastAutoSkipEvent: PlaybackAutoSkipEvent?
    public private(set) var skipBackwardInterval: TimeInterval = PlaybackSkipInterval.backward
    public private(set) var skipForwardInterval: TimeInterval = PlaybackSkipInterval.forward
    public private(set) var playbackDiagnosticsText = ""

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let nowPlayingPublisher: NowPlayingInfoPublisher
    @ObservationIgnored private let remoteCommandController = RemoteCommandController()
    @ObservationIgnored private var timeObserver: PlayerTimeObserver?
    @ObservationIgnored private var mediaClockObservers: [UUID: PlayerTimeObserver] = [:]
    @ObservationIgnored private var mediaClockContinuations: [UUID: AsyncStream<PlaybackMediaClockSample>.Continuation] = [:]
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
    @ObservationIgnored private let audioSessionActivation: PlaybackAudioSessionActivation
    @ObservationIgnored private var voiceBoostConfiguration = VoiceBoostConfiguration.default
    @ObservationIgnored var isAudioSessionActive = false
    @ObservationIgnored private var audioSessionActivationTask: Task<Void, Never>?
    @ObservationIgnored private var audioSessionActivationGeneration = 0
    @ObservationIgnored private var isPlaybackRequested = false
    @ObservationIgnored private var shouldResumeAfterInterruption = false
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var remotePlaybackRateChangeHandler: PlaybackRateChangeRequestHandler?
    @ObservationIgnored private var episodeFinishedHandler: PlaybackEpisodeFinishedHandler?
    @ObservationIgnored private var nextTrackHandler: PlaybackNextTrackHandler?
    @ObservationIgnored private var hasQueuedNextEpisode = false
    @ObservationIgnored private var playbackPositionProtection = PlaybackPositionProtection()
    @ObservationIgnored private var playbackAdSkipPolicy = PlaybackAdSkipPolicy()
    @ObservationIgnored private var playbackFailureRecoveryPolicy = PlaybackFailureRecoveryPolicy()
    @ObservationIgnored private var autoSkipEventSequence = 0
    @ObservationIgnored private var pendingAutoSkipTarget: TimeInterval?
    @ObservationIgnored private var isPlaybackDiagnosticsEnabled = false
    @ObservationIgnored private var playbackDiagnosticsEvents: [String] = []
    @ObservationIgnored var playbackStartBehaviorObserver: ((PlaybackStartBehavior) -> Void)?

    public convenience init(
        voiceBoostTapDiagnostics: VoiceBoostAudioTapDiagnostics? = nil,
        nowPlayingArtworkLoader: (any NowPlayingArtworkLoading)? = nil
    ) {
        self.init(
            voiceBoostTapDiagnostics: voiceBoostTapDiagnostics,
            nowPlayingArtworkLoader: nowPlayingArtworkLoader,
            voiceBoostAudioTapFactory: {
                try VoiceBoostAudioTap(configuration: $0, diagnostics: $1)
            }
        )
    }

    init(
        voiceBoostTapDiagnostics: VoiceBoostAudioTapDiagnostics?,
        nowPlayingArtworkLoader: (any NowPlayingArtworkLoading)? = nil,
        audioSessionActivation: @escaping PlaybackAudioSessionActivation = {
            try await activateSystemPlaybackAudioSession()
        },
        voiceBoostAudioTapFactory: @escaping VoiceBoostAudioTapFactory = {
            try VoiceBoostAudioTap(configuration: $0, diagnostics: $1)
        }
    ) {
        self.nowPlayingPublisher = NowPlayingInfoPublisher(
            artworkLoader: nowPlayingArtworkLoader ?? DefaultNowPlayingArtworkLoader()
        )
        self.voiceBoostTapDiagnostics = voiceBoostTapDiagnostics
        self.voiceBoostAudioTapFactory = voiceBoostAudioTapFactory
        self.audioSessionActivation = audioSessionActivation
        installPeriodicTimeObserver()
        observePlayerTimeControlStatus()
        installAudioSessionObservers()
        installRemoteCommands()
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver.token)
        }
        for observer in mediaClockObservers.values {
            player.removeTimeObserver(observer.token)
        }
        mediaClockObservers.removeAll()
        for continuation in mediaClockContinuations.values {
            continuation.finish()
        }
        mediaClockContinuations.removeAll()
        removeCurrentItemObservations()
        playerTimeControlStatusObservation?.invalidate()
        removeAudioSessionObservers()
        voiceBoostTrackLoadTask?.cancel()
        audioSessionActivationTask?.cancel()
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
        playbackPositionProtection.clear()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        isPlaybackRequested = false
        playbackFailureRecoveryPolicy.reset()
        playbackAdSkipPolicy.setZones([])
        autoSkipEventSequence = 0
        lastAutoSkipEvent = nil
        pendingAutoSkipTarget = nil
        if sleepTimerMode == .endOfEpisode {
            clearSleepTimer()
        }

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

        let playerItem = makeDirectPlayerItem(audioURL: audioURL)
        player.replaceCurrentItem(with: playerItem)
        observeCurrentItem(playerItem)

        if snapshot.position > 0 {
            seekPlayer(to: snapshot.position, mode: .restoredPosition)
        }

        snapshot.state = .paused
        if snapshot.position == 0 {
            evaluateAutoSkip(
                previousPosition: -Double.ulpOfOne,
                position: 0,
                cause: .playStart
            )
        }
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

    public func setSkipZones(_ zones: [PlaybackSkipZone]) {
        playbackAdSkipPolicy.setZones(zones)
        snapshot.skipZones = playbackAdSkipPolicy.zones
        syncObservableState()

        guard snapshot.currentEpisode != nil else {
            return
        }

        let cause: PlaybackAdSkipPolicy.EvaluationCause = if snapshot.position == 0 {
            .playStart
        } else {
            .seekLanding(.restore)
        }
        evaluateAutoSkip(
            previousPosition: snapshot.position == 0 ? -Double.ulpOfOne : nil,
            position: snapshot.position,
            cause: cause
        )
    }

    public func setAutoSkipEnabled(_ isEnabled: Bool) {
        playbackAdSkipPolicy.setEnabled(isEnabled)
        guard isEnabled, snapshot.currentEpisode != nil else {
            return
        }

        evaluateAutoSkip(
            previousPosition: nil,
            position: snapshot.position,
            cause: .seekLanding(.restore)
        )
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

        if let duration = resolvedDuration(), snapshot.position >= duration - 0.25 {
            currentVoiceBoostTap?.reset()
            seekPlayer(to: 0)
            snapshot.position = 0
            markProgressBoundary()
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

        guard !isAudioSessionActive else {
            requestPlaybackForCurrentItem()
            return
        }

        beginAudioSessionActivation()
    }

    public func pause() {
        pause(reason: "api")
    }

    private func pause(reason: String) {
        isPlaybackRequested = false
        shouldResumeAfterInterruption = false
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
        invalidateAudioSessionActivation()
        removeCurrentItemObservations()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        clearSleepTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentVoiceBoostTap = nil
        playbackPositionProtection.clear()
        playbackAdSkipPolicy.setZones([])
        autoSkipEventSequence = 0
        lastAutoSkipEvent = nil
        pendingAutoSkipTarget = nil
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
        if snapshot.state.showsPauseButton {
            pause(reason: "toggle \(source)")
        } else {
            play(source: "toggle \(source)")
        }
    }

    public func seek(to position: TimeInterval) {
        seek(to: position, intent: .scrub)
    }

    public func seek(to position: TimeInterval, intent: PlaybackSeekIntent) {
        guard snapshot.currentEpisode != nil, position.isFinite else {
            return
        }

        let clamped = clampedPosition(position)
        currentVoiceBoostTap?.reset()
        seekPlayer(to: clamped, mode: .userInitiated(intent))
        snapshot.position = clamped
        markProgressBoundary()
        recordDiagnosticsEvent("seek requested position=\(diagnosticsTime(clamped)) intent=\(intent)")
        publishPlaybackState()
    }

    public func skip(by interval: TimeInterval) {
        seek(to: snapshot.position + interval, intent: .skipButton)
    }

    public func setRate(_ rate: Float) {
        snapshot.rate = clampedPlaybackRate(rate)
        if isPlaybackRequested, isAudioSessionActive {
            player.rate = snapshot.rate
        }
        publishPlaybackState()
    }

    public func setRemotePlaybackRateChangeHandler(
        _ handler: PlaybackRateChangeRequestHandler?
    ) {
        remotePlaybackRateChangeHandler = handler
    }

    public func setEpisodeFinishedHandler(_ handler: PlaybackEpisodeFinishedHandler?) {
        episodeFinishedHandler = handler
    }

    public func setNextTrackHandler(_ handler: PlaybackNextTrackHandler?) {
        nextTrackHandler = handler
    }

    public func setHasQueuedNextEpisode(_ hasQueuedNextEpisode: Bool) {
        guard self.hasQueuedNextEpisode != hasQueuedNextEpisode else {
            return
        }

        self.hasQueuedNextEpisode = hasQueuedNextEpisode
    }

    public func sleepTimerRemaining(at date: Date = .now) -> TimeInterval? {
        switch sleepTimerMode {
        case .off:
            nil
        case .duration:
            snapshot.sleepTimerEndsAt.map { max(0, $0.timeIntervalSince(date)) }
        case .endOfEpisode:
            PlaybackEndOfEpisodeSleepTimer.remainingPlaybackDuration(
                duration: resolvedDuration(),
                position: snapshot.position,
                rate: snapshot.rate
            )
        }
    }

    public func setSleepTimer(duration: TimeInterval?) {
        setSleepTimer(mode: duration.map(PlaybackSleepTimerMode.duration) ?? .off)
    }

    public func setSleepTimer(mode: PlaybackSleepTimerMode) {
        setSleepTimer(mode: mode, now: .now)
    }

    func setSleepTimer(mode: PlaybackSleepTimerMode, now: Date) {
        sleepTimerTask?.cancel()

        switch mode {
        case .off:
            sleepTimerMode = .off
            snapshot.sleepTimerEndsAt = nil
            syncObservableState()
        case .duration(let duration):
            guard duration > 0 else {
                sleepTimerMode = .off
                snapshot.sleepTimerEndsAt = nil
                syncObservableState()
                return
            }
            sleepTimerMode = .duration(duration)
            scheduleSleepTimer(after: duration, now: now)
        case .endOfEpisode:
            guard snapshot.currentEpisode != nil else {
                sleepTimerMode = .off
                snapshot.sleepTimerEndsAt = nil
                syncObservableState()
                return
            }
            sleepTimerMode = .endOfEpisode
            snapshot.sleepTimerEndsAt = nil
            syncObservableState()
        }
    }

    private func scheduleSleepTimer(after duration: TimeInterval, now: Date) {
        let endsAt = now.addingTimeInterval(duration)
        snapshot.sleepTimerEndsAt = endsAt
        syncObservableState()
        sleepTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
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

                let previousPosition = snapshot.position
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

                if evaluateAutoSkip(
                    previousPosition: previousPosition,
                    position: newPosition,
                    cause: .acceptedTick
                ) {
                    return
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

    /// Display-cadence media-time samples for one consumer, independent of the
    /// 1 Hz snapshot publication. Each call installs its own periodic observer,
    /// removed when the consuming task ends, so `.task(id:)` is the intended
    /// lifecycle. Samples read the player directly and never mutate `snapshot`.
    public func mediaClockSamples(
        interval: TimeInterval = 1.0 / 30.0
    ) -> AsyncStream<PlaybackMediaClockSample> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackMediaClockSample.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        mediaClockContinuations[id] = continuation
        mediaClockObservers[id] = PlayerTimeObserver(token: player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            // AVPlayer invokes this callback on the explicitly supplied main
            // queue, so avoid allocating a MainActor hop at display cadence.
            MainActor.assumeIsolated {
                guard let self, let sample = self.currentMediaClockSample() else {
                    return
                }
                continuation.yield(sample)
            }
        })
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeMediaClockClient(id)
            }
        }
        // Prime so a consumer that subscribes while paused renders immediately
        // instead of waiting for playback to produce the first callback.
        if let sample = currentMediaClockSample() {
            continuation.yield(sample)
        }
        return stream
    }

    var mediaClockClientCount: Int {
        mediaClockObservers.count
    }

    public var currentItemSourceIdentity: PlaybackItemSourceIdentity? {
        guard let item = player.currentItem, let asset = item.asset as? AVURLAsset else {
            return nil
        }

        let kind: PlaybackItemSourceIdentity.Kind = if asset.url.isFileURL {
            .localFile
        } else {
            .networkStream
        }
        let itemDuration = item.duration.seconds
        return PlaybackItemSourceIdentity(
            assetURL: asset.url,
            kind: kind,
            itemDuration: itemDuration.isFinite && itemDuration > 0 ? itemDuration : nil
        )
    }

    private func currentMediaClockSample() -> PlaybackMediaClockSample? {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else {
            return nil
        }
        return PlaybackMediaClockSample(
            position: seconds,
            rate: player.rate,
            isPlaying: player.timeControlStatus == .playing
        )
    }

    private func removeMediaClockClient(_ id: UUID) {
        if let observer = mediaClockObservers.removeValue(forKey: id) {
            player.removeTimeObserver(observer.token)
        }
        mediaClockContinuations.removeValue(forKey: id)?.finish()
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
            nextTrack: { [weak self] in
                self?.handleNextTrackCommand()
            },
            seek: { [weak self] position in
                self?.seek(to: position, intent: .scrub)
            },
            changeRate: { [weak self] rate in
                self?.handleRemotePlaybackRateChange(rate)
            }
        ))
    }

    private func skipForward() {
        skip(by: skipForwardInterval)
    }

    private func skipBackward() {
        skip(by: -skipBackwardInterval)
    }

    func handleNextTrackCommand() {
        if hasQueuedNextEpisode, let nextTrackHandler {
            nextTrackHandler()
        } else {
            skipForward()
        }
    }

    func handleRemotePlaybackRateChange(_ rate: Float) {
        if let remotePlaybackRateChangeHandler {
            remotePlaybackRateChangeHandler(rate)
        } else {
            setRate(rate)
        }
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
        invalidateAudioSessionActivation()
        isAudioSessionActive = false
        recordDiagnosticsEvent("audio session media services reset")

        guard isPlaybackRequested, snapshot.currentEpisode != nil else {
            return
        }

        play(source: "audio session media services reset")
    }

    func handleAudioSessionInterruptionBegan() {
        let recordedResumeIntent = PlaybackInterruptionResumePolicy.shouldRecordResumeIntent(
            isPlaybackRequested: isPlaybackRequested,
            state: snapshot.state
        )
        invalidateAudioSessionActivation()
        isAudioSessionActive = false
        guard snapshot.currentEpisode != nil else {
            isPlaybackRequested = false
            player.pause()
            shouldResumeAfterInterruption = false
            return
        }
        pause(reason: "audio session interruption began")
        shouldResumeAfterInterruption = recordedResumeIntent
    }

    func handleAudioSessionInterruptionEnded(shouldResume: Bool) {
        defer {
            shouldResumeAfterInterruption = false
        }

        guard PlaybackInterruptionResumePolicy.shouldResume(
            operatingSystemShouldResume: shouldResume,
            recordedResumeIntent: shouldResumeAfterInterruption,
            hasCurrentEpisode: snapshot.currentEpisode != nil
        ) else {
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
            handleAudioSessionOldDeviceUnavailable()
        default:
            break
        }
        #endif
    }

    func handleAudioSessionOldDeviceUnavailable() {
        guard snapshot.currentEpisode != nil else {
            return
        }

        if case .failed = snapshot.state {
            shouldResumeAfterInterruption = false
            recordDiagnosticsEvent("old audio route unavailable while playback failed")
            return
        }

        pause(reason: "old audio route unavailable")
    }

    private func makeDirectPlayerItem(audioURL: URL) -> AVPlayerItem {
        // Local files get a precise timeline: karaoke equates item media time
        // with transcript timestamps, and estimated MP3 timing (the default)
        // can report a duration and land seeks at bytes that do not
        // correspond to the requested time in stitched or VBR files.
        let options: [String: Any]? = audioURL.isFileURL
            ? [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            : nil
        let asset = AVURLAsset(url: audioURL, options: options)
        return configuredPlayerItem(asset: asset)
    }

    private func configuredPlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: asset)
        installVoiceBoostTap(on: playerItem)
        scheduleTrackBoundVoiceBoostTapInstall(for: playerItem, asset: asset)
        return playerItem
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
        // The track-bound reinstall replaces a live tap on the same item;
        // carry the adaptation control state so gain does not re-bootstrap
        // through the low-confidence cap (I3). Item changes pass no track
        // here, so a new episode always starts fresh.
        let carriedControlSnapshot = audioTrack != nil
            ? currentVoiceBoostTap?.captureControlSnapshot()
            : nil
        currentVoiceBoostTap = nil
        guard voiceBoostConfiguration.isEnabled else {
            playerItem.audioMix = nil
            return
        }

        do {
            voiceBoostTapDiagnostics?.recordTapInstallAttempt()
            let tap = try voiceBoostAudioTapFactory(voiceBoostConfiguration, voiceBoostTapDiagnostics)
            voiceBoostTapDiagnostics?.recordTapInstallSuccess()
            if let carriedControlSnapshot {
                tap.seedControlSnapshot(carriedControlSnapshot)
            }
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
                self?.handleCurrentItemDidPlayToEnd(playerItem)
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
        guard snapshot.currentEpisode != nil, isPlaybackRequested, isAudioSessionActive else {
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
            if isPlaybackRequested, isAudioSessionActive {
                transitionToBuffering(reason: "item status unknown")
            }
        case .readyToPlay:
            if updateDuration(from: playerItem.duration) {
                publishPlaybackState()
            }
            if isPlaybackRequested {
                if isAudioSessionActive {
                    requestPlaybackForReadyItem(playerItem)
                }
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
              isPlaybackRequested,
              isAudioSessionActive
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

        handleCurrentItemPlaybackStalled()
    }

    func handleCurrentItemPlaybackStalled() {
        if isPlaybackRequested {
            recordDiagnosticsEvent("playback stalled at \(diagnosticsTime(snapshot.position))")
            transitionToBuffering(reason: "AVPlayerItemPlaybackStalled")
            resumeUsingAutomaticBufferWaiting()
        }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        player.automaticallyWaitsToMinimizeStalling
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

        // This path follows an explicit user request, so immediate start is
        // preferable to AVPlayer extending the tap-to-audio delay.
        playbackStartBehaviorObserver?(.immediateUserRequest)
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

    private func resumeUsingAutomaticBufferWaiting() {
        playbackStartBehaviorObserver?(.automaticBufferWaiting)
        player.defaultRate = snapshot.rate
        player.play()
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
        playbackPositionProtection.clear()
        voiceBoostTrackLoadTask?.cancel()
        voiceBoostTrackLoadTask = nil
        currentVoiceBoostTap = nil
        player.pause()

        let retryItem = makeDirectPlayerItem(audioURL: audioURL)
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

    private func handleFailedCurrentItem(_ playerItem: AVPlayerItem) {
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
        shouldResumeAfterInterruption = false
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

    func handleCurrentItemDidPlayToEnd(_ playerItem: AVPlayerItem) {
        guard player.currentItem === playerItem else {
            return
        }

        handleCurrentItemDidPlayToEnd()
    }

    func handleCurrentItemDidPlayToEnd() {
        let finishedEpisode = snapshot.currentEpisode
        let sleepGated = sleepTimerMode == .endOfEpisode
        isPlaybackRequested = false
        shouldResumeAfterInterruption = false
        if let duration = resolvedDuration() {
            snapshot.duration = duration
            snapshot.position = duration
        }
        player.pause()
        if sleepTimerMode == .endOfEpisode {
            clearSleepTimer()
        }
        snapshot.state = snapshot.currentEpisode == nil ? .idle : .paused
        markProgressBoundary()
        publishPlaybackState()
        if !sleepGated, let finishedEpisode {
            episodeFinishedHandler?(finishedEpisode)
        }
    }

    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        clampPlaybackPosition(position, to: resolvedDuration())
    }

    private enum SeekMode {
        case userInitiated(PlaybackSeekIntent)
        case restoredPosition
        case autoSkip

        var intent: PlaybackSeekIntent {
            switch self {
            case .userInitiated(let intent):
                intent
            case .restoredPosition:
                .restore
            case .autoSkip:
                .autoSkip
            }
        }
    }

    private func seekPlayer(to position: TimeInterval, mode: SeekMode = .userInitiated(.scrub)) {
        let clamped = clampedPosition(position)
        switch mode {
        case .autoSkip:
            pendingAutoSkipTarget = clamped
        case .userInitiated, .restoredPosition:
            pendingAutoSkipTarget = nil
        }
        let protectedSeekGeneration = playbackPositionProtection.startSeek(to: clamped)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let completion: @Sendable (Bool) -> Void = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.completeProtectedSeek(
                    generation: protectedSeekGeneration,
                    finished: finished,
                    position: clamped,
                    intent: mode.intent
                )
            }
        }

        switch mode {
        case .userInitiated, .autoSkip:
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

    private func completeProtectedSeek(
        generation: Int?,
        finished: Bool,
        position: TimeInterval,
        intent: PlaybackSeekIntent
    ) {
        guard let generation else {
            return
        }

        playbackPositionProtection.completeSeek(generation: generation, finished: finished)
        if finished {
            evaluateAutoSkip(
                previousPosition: nil,
                position: position,
                cause: .seekLanding(intent)
            )
        }
        refreshPlaybackDiagnosticsText()
    }

    @discardableResult
    private func evaluateAutoSkip(
        previousPosition: TimeInterval?,
        position: TimeInterval,
        cause: PlaybackAdSkipPolicy.EvaluationCause
    ) -> Bool {
        guard let command = playbackAdSkipPolicy.evaluate(
            previousPosition: previousPosition,
            position: position,
            duration: resolvedDuration(),
            cause: cause
        ) else {
            return false
        }

        performAutoSkip(command, from: position)
        return true
    }

    private func performAutoSkip(_ command: PlaybackAdSkipPolicy.Command, from position: TimeInterval) {
        guard snapshot.currentEpisode != nil else {
            return
        }

        switch command {
        case .skip(let target, let zoneID):
            currentVoiceBoostTap?.reset()
            autoSkipEventSequence += 1
            lastAutoSkipEvent = PlaybackAutoSkipEvent(zoneID: zoneID, sequence: autoSkipEventSequence)
            seekPlayer(to: target, mode: .autoSkip)
            snapshot.position = target
            markProgressBoundary()
            recordDiagnosticsEvent(
                "auto-skip zone=\(zoneID) from=\(diagnosticsTime(position)) to=\(diagnosticsTime(target))"
            )
            publishPlaybackState()
        }
    }

    private func shouldAcceptObservedPosition(_ position: TimeInterval) -> Bool {
        if case .failed = snapshot.state {
            return false
        }

        if let pendingAutoSkipTarget {
            guard position + Self.autoSkipSettleTolerance >= pendingAutoSkipTarget else {
                return false
            }
            self.pendingAutoSkipTarget = nil
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
        setIfChanged(\.skipZones, to: snapshot.skipZones)
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
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = .off
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

    private func recordDiagnosticsEvent(_ event: @autoclosure () -> String) {
        guard isPlaybackDiagnosticsEnabled else {
            return
        }

        let timestamp = Date.now.formatted(.dateTime.hour().minute().second())
        playbackDiagnosticsEvents.append("[\(timestamp)] \(event())")
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

    private func beginAudioSessionActivation() {
        guard audioSessionActivationTask == nil else {
            return
        }

        audioSessionActivationGeneration += 1
        let generation = audioSessionActivationGeneration
        let activation = audioSessionActivation
        snapshot.state = .loading
        publishPlaybackState()

        audioSessionActivationTask = Task { [weak self] in
            do {
                let didRetry = try await activation()
                self?.completeAudioSessionActivation(
                    generation: generation,
                    didRetry: didRetry
                )
            } catch is CancellationError {
            } catch {
                self?.completeAudioSessionActivation(
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func completeAudioSessionActivation(
        generation: Int,
        didRetry: Bool
    ) {
        guard generation == audioSessionActivationGeneration else {
            return
        }

        audioSessionActivationTask = nil
        isAudioSessionActive = true
        if didRetry {
            recordDiagnosticsEvent("audio session activated after retry")
        }
        guard isPlaybackRequested, snapshot.currentEpisode != nil else {
            return
        }
        requestPlaybackForCurrentItem()
    }

    private func completeAudioSessionActivation(
        generation: Int,
        error: any Error
    ) {
        guard generation == audioSessionActivationGeneration else {
            return
        }

        audioSessionActivationTask = nil
        isAudioSessionActive = false
        recordDiagnosticsEvent("audio session activation retry failed: \(error.localizedDescription)")
        guard isPlaybackRequested else {
            return
        }
        failPlayback(message: "Unable to activate audio session: \(error.localizedDescription)")
    }

    private func invalidateAudioSessionActivation() {
        audioSessionActivationGeneration += 1
        audioSessionActivationTask?.cancel()
        audioSessionActivationTask = nil
    }

    var currentPlayerRate: Float {
        player.rate
    }

    var currentPlayerDefaultRate: Float {
        player.defaultRate
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
            Self.logger.debug(
                "Audio session deactivation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }
}
