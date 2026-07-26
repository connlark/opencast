import CarPlay
import Foundation
import Observation
import OpenCastPlayback
import os
import SwiftData
import SwiftUI

/// Owns the car's template stack: the tab bar and its three lists, the Now
/// Playing screen's custom controls, the observation loops that keep both
/// fresh, row selection, and the artwork patch pipeline. Created on connect,
/// torn down on disconnect.
final class CarPlayInterfaceCoordinator {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "CarPlay")

    private let appModel: OpenCastAppModel
    private let modelContext: ModelContext
    private let artworkPatcher = CarPlayArtworkPatcher()

    private var interfaceController: CPInterfaceController?
    private var renderer = CarPlayTemplateRenderer(artworkSizing: .fallback)
    private var limits = CarPlayListLimits.fallback
    private var inboxTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private var renderedSnapshots: CarPlayBrowseSnapshots?
    private var nowPlayingConfigurator: CarPlayNowPlayingConfigurator?
    private var observationTask: Task<Void, Never>?
    private var buttonStateTask: Task<Void, Never>?
    private var hydrationTask: Task<Void, Never>?
    private var isHydrating = true

    init(appModel: OpenCastAppModel, modelContext: ModelContext) {
        self.appModel = appModel
        self.modelContext = modelContext
    }

    func start(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        limits = CarPlayListLimits(
            maximumItemCount: Int(CPListTemplate.maximumItemCount),
            maximumSectionCount: Int(CPListTemplate.maximumSectionCount)
        )
        renderer = CarPlayTemplateRenderer(
            artworkSizing: CarPlayArtworkSizing(
                pointSize: CPListItem.maximumImageSize,
                displayScale: interfaceController.carTraitCollection.displayScale
            )
        )

        let snapshots = makeSnapshots()
        interfaceController.setRootTemplate(
            makeTabBarTemplate(for: snapshots),
            animated: false,
            completion: nil
        )
        renderedSnapshots = snapshots
        startObserving()
        startNowPlayingConfiguration()
        startHydration()
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        buttonStateTask?.cancel()
        buttonStateTask = nil
        hydrationTask?.cancel()
        hydrationTask = nil
        nowPlayingConfigurator?.tearDown()
        nowPlayingConfigurator = nil
        artworkPatcher.cancelAll()
        // Losing the car can be the last thing that happens before the process
        // goes away, so bank the current position now.
        appModel.flushPlaybackProgress(modelContext: modelContext, refreshObservableProgress: false)
        interfaceController = nil
        inboxTemplate = nil
        libraryTemplate = nil
        downloadsTemplate = nil
        renderedSnapshots = nil
    }

    private func makeTabBarTemplate(for snapshots: CarPlayBrowseSnapshots) -> CPTabBarTemplate {
        let inbox = makeTabTemplate(
            for: snapshots.inbox,
            tabTitle: "Inbox",
            tabSystemImageName: "tray",
            scope: .inbox
        )
        let library = makeTabTemplate(
            for: snapshots.library,
            tabTitle: "Library",
            tabSystemImageName: "books.vertical",
            scope: .library
        )
        let downloads = makeTabTemplate(
            for: snapshots.downloads,
            tabTitle: "Downloads",
            tabSystemImageName: "arrow.down.circle",
            scope: .downloads
        )
        inboxTemplate = inbox
        libraryTemplate = library
        downloadsTemplate = downloads

        // Staying inside the tab cap keeps the system Now Playing button visible,
        // which is the driver's other way back to what is playing.
        let templates = [inbox, library, downloads].prefix(max(CPTabBarTemplate.maximumTabCount, 1))
        return CPTabBarTemplate(templates: Array(templates))
    }

    private func makeTabTemplate(
        for snapshot: CarPlayBrowseSnapshot,
        tabTitle: String,
        tabSystemImageName: String,
        scope: CarPlayArtworkPatcher.Scope
    ) -> CPListTemplate {
        let rendered = renderer.makeTemplate(for: snapshot) { [weak self] row in
            self?.handleSelection(of: row, in: snapshot, returnsToNowPlaying: false)
        }
        rendered.template.tabTitle = tabTitle
        rendered.template.tabImage = UIImage(systemName: tabSystemImageName)
        patch(rendered.artworkTargets, scope: scope)
        return rendered.template
    }

    private func startObserving() {
        let appModel = appModel
        let limits = limits
        observationTask = Task { [weak self] in
            let snapshots = Observations { [weak self] in
                Self.makeSnapshots(
                    appModel: appModel,
                    limits: limits,
                    isHydrating: self?.isHydrating ?? false
                )
            }
            for await snapshots in snapshots {
                guard let self else {
                    return
                }
                apply(snapshots)
            }
        }
    }

    /// The Now Playing screen is configured at connect because the system can
    /// present the shared template on the app's behalf at any time — including
    /// before the driver ever taps a row.
    private func startNowPlayingConfiguration() {
        let configurator = CarPlayNowPlayingConfigurator(actions: makeNowPlayingActions())
        nowPlayingConfigurator = configurator
        configurator.start(with: makeButtonState())
        startObservingButtonState()
    }

    /// Buttons change on their own cadence — a rate tap or a toggle — so they
    /// get a loop of their own rather than riding the browse lists'. It reads
    /// no per-second state.
    private func startObservingButtonState() {
        let appModel = appModel
        buttonStateTask = Task { [weak self] in
            let states = Observations { Self.makeButtonState(appModel: appModel) }
            for await state in states {
                guard let self else {
                    return
                }
                nowPlayingConfigurator?.apply(state)
            }
        }
    }

    private func makeNowPlayingActions() -> CarPlayNowPlayingActions {
        CarPlayNowPlayingActions(
            cycleRate: { [weak self] in self?.cycleRate() },
            toggleVoiceBoost: { [weak self] in self?.toggleVoiceBoost() },
            showUpNext: { [weak self] in self?.pushInbox() },
            showCurrentShow: { [weak self] in self?.pushCurrentShow() }
        )
    }

    private func makeButtonState() -> CarPlayNowPlayingButtonState {
        Self.makeButtonState(appModel: appModel)
    }

    private static func makeButtonState(appModel: OpenCastAppModel) -> CarPlayNowPlayingButtonState {
        let playback = appModel.playback
        let playbackSettings = appModel.playbackSettings
        let currentEpisode = playback.currentEpisode

        return CarPlayNowPlayingModelBuilder.buttonState(
            rate: playback.rate,
            hasLoadedEpisode: currentEpisode != nil,
            isCurrentShowSubscribed: currentEpisode.map { episode in
                appModel.library.isActivelySubscribed(to: episode.podcastID.rawValue)
            } ?? false,
            isVoiceBoostEnabled: playbackSettings.isVoiceBoostEnabled,
            canChangeVoiceBoost: playbackSettings.canChangeCurrentEpisodeVoiceBoost
        )
    }

    private func cycleRate() {
        let playback = appModel.playback
        playback.setRate(PlaybackRateSteps.next(after: playback.rate))
    }

    private func toggleVoiceBoost() {
        guard let episode = appModel.playback.currentEpisode else {
            return
        }

        appModel.setVoiceBoostEnabled(
            !appModel.playbackSettings.isVoiceBoostEnabled,
            forEpisodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            modelContext: modelContext
        )
    }

    /// The car can be the first surface the app opens on, so hydration runs here
    /// too. The store mutations it makes are exactly what the observation loop
    /// tracks; the final flag flip needs its own render because it is not
    /// observable state.
    private func startHydration() {
        hydrationTask = Task { [weak self] in
            guard let appModel = self?.appModel, let modelContext = self?.modelContext else {
                return
            }

            await appModel.ensureCoreStoresLoaded(modelContext: modelContext)
            // Skip zones and the auto-detect decision are read the moment an
            // episode loads or a row is tapped, so transcripts and ad analyses
            // have to be in memory before either can happen.
            await appModel.ensurePlaybackDependenciesLoaded(modelContext: modelContext)
            guard let self, !Task.isCancelled else {
                return
            }

            appModel.startPlaybackProgressPersistence(modelContext: modelContext)
            appModel.restorePreviousPlaybackIfAvailable(modelContext: modelContext)
            appModel.restoreAdFreePassQueue(modelContext: modelContext)
            isHydrating = false
            apply(makeSnapshots())
        }
    }

    private func makeSnapshots() -> CarPlayBrowseSnapshots {
        Self.makeSnapshots(appModel: appModel, limits: limits, isHydrating: isHydrating)
    }

    /// `state` is published only on real transitions, not per position tick, so
    /// reading it costs nothing per second.
    private static func nowPlayingState(appModel: OpenCastAppModel) -> CarPlayNowPlayingState {
        CarPlayNowPlayingState(
            episodeID: appModel.playback.currentEpisode?.id.rawValue,
            isPlaying: appModel.playback.state == .playing
        )
    }

    private static func makeSnapshots(
        appModel: OpenCastAppModel,
        limits: CarPlayListLimits,
        isHydrating: Bool
    ) -> CarPlayBrowseSnapshots {
        let library = appModel.library
        let downloadRecords = appModel.downloads.records
        let currentEpisode = appModel.playback.currentEpisode
        let nowPlaying = nowPlayingState(appModel: appModel)
        let isLoading = isHydrating || library.state == .loading

        return CarPlayBrowseSnapshots(
            inbox: CarPlayBrowseModelBuilder.inbox(
                library: library,
                downloadRecords: downloadRecords,
                currentEpisode: currentEpisode,
                nowPlaying: nowPlaying,
                isLoading: isLoading,
                limits: limits
            ),
            library: CarPlayBrowseModelBuilder.library(
                subscriptions: library.subscriptions,
                library: library,
                isLoading: isLoading,
                limits: limits
            ),
            downloads: CarPlayBrowseModelBuilder.downloads(
                records: downloadRecords,
                library: library,
                nowPlaying: nowPlaying,
                isLoading: isLoading,
                limits: limits
            )
        )
    }

    private func apply(_ snapshots: CarPlayBrowseSnapshots) {
        guard interfaceController != nil, renderedSnapshots != snapshots else {
            return
        }

        if let inboxTemplate, renderedSnapshots?.inbox != snapshots.inbox {
            patch(update(inboxTemplate, with: snapshots.inbox), scope: .inbox)
        }
        if let libraryTemplate, renderedSnapshots?.library != snapshots.library {
            patch(update(libraryTemplate, with: snapshots.library), scope: .library)
        }
        if let downloadsTemplate, renderedSnapshots?.downloads != snapshots.downloads {
            patch(update(downloadsTemplate, with: snapshots.downloads), scope: .downloads)
        }
        renderedSnapshots = snapshots
    }

    private func patch(_ targets: [CarPlayArtworkTarget], scope: CarPlayArtworkPatcher.Scope) {
        artworkPatcher.patch(targets, sizing: renderer.artworkSizing, scope: scope)
    }

    private func update(
        _ template: CPListTemplate,
        with snapshot: CarPlayBrowseSnapshot
    ) -> [CarPlayArtworkTarget] {
        renderer.update(template, with: snapshot) { [weak self] row in
            self?.handleSelection(of: row, in: snapshot, returnsToNowPlaying: false)
        }
    }

    private func handleSelection(
        of row: CarPlayListRow,
        in snapshot: CarPlayBrowseSnapshot,
        returnsToNowPlaying: Bool
    ) {
        switch row {
        case .episode(let episodeRow):
            play(episodeRow, returnsToNowPlaying: returnsToNowPlaying)
        case .podcast(let podcastRow):
            pushEpisodes(for: podcastRow)
        case .showMore:
            pushContinuation(snapshot.continuation)
        }
    }

    private func play(_ row: CarPlayEpisodeRow, returnsToNowPlaying: Bool) {
        let playback = appModel.playback
        if playback.currentEpisode?.id.rawValue == row.episodeID {
            if playback.state != .playing {
                playback.play()
            }
            showNowPlaying(returningToIt: returnsToNowPlaying)
            return
        }

        guard let episode = appModel.episodeSnapshot(for: row.episodeID) else {
            presentPlaybackFailure()
            return
        }

        do {
            try appModel.playEpisode(episode, presentsNowPlaying: false, modelContext: modelContext)
            showNowPlaying(returningToIt: returnsToNowPlaying)
        } catch {
            presentPlaybackFailure()
        }
    }

    private func pushEpisodes(for row: CarPlayPodcastRow) {
        push(
            CarPlayBrowseModelBuilder.episodes(
                forPodcastID: row.feedURL,
                title: row.title,
                library: appModel.library,
                downloadRecords: appModel.downloads.records,
                episodeListSettings: appModel.podcastEpisodeListSettings,
                nowPlaying: Self.nowPlayingState(appModel: appModel),
                limits: limits
            )
        )
    }

    /// Up Next is the Inbox without its Continue row: the episode that row would
    /// carry is the screen this list was pushed from.
    private func pushInbox() {
        push(
            CarPlayBrowseModelBuilder.inbox(
                library: appModel.library,
                downloadRecords: appModel.downloads.records,
                currentEpisode: nil,
                nowPlaying: Self.nowPlayingState(appModel: appModel),
                isLoading: isHydrating || appModel.library.state == .loading,
                limits: limits.withoutContinuation
            ),
            returnsToNowPlaying: true
        )
    }

    private func pushCurrentShow() {
        guard let episode = appModel.playback.currentEpisode else {
            return
        }

        push(
            CarPlayBrowseModelBuilder.episodes(
                forPodcastID: episode.podcastID.rawValue,
                title: episode.podcastTitle,
                library: appModel.library,
                downloadRecords: appModel.downloads.records,
                episodeListSettings: appModel.podcastEpisodeListSettings,
                nowPlaying: Self.nowPlayingState(appModel: appModel),
                limits: limits.withoutContinuation
            ),
            returnsToNowPlaying: true
        )
    }

    private func pushContinuation(_ continuation: CarPlayListContinuation?) {
        guard let continuation else {
            return
        }

        push(continuation.snapshot)
    }

    private func push(_ snapshot: CarPlayBrowseSnapshot, returnsToNowPlaying: Bool = false) {
        guard let interfaceController else {
            return
        }

        let rendered = renderer.makeTemplate(for: snapshot) { [weak self] row in
            self?.handleSelection(
                of: row,
                in: snapshot,
                returnsToNowPlaying: returnsToNowPlaying
            )
        }
        interfaceController.pushTemplate(rendered.template, animated: true) { didPush, error in
            Self.logTemplateFailure("push list", didSucceed: didPush, error: error)
        }
        artworkPatcher.patch(rendered.artworkTargets, sizing: renderer.artworkSizing, scope: .pushed)
    }

    /// A list pushed from Now Playing sits directly on top of it, so playing a
    /// row returns to the screen the driver came from instead of stacking a
    /// second copy past the template ceiling.
    private func showNowPlaying(returningToIt: Bool) {
        guard returningToIt else {
            pushNowPlaying()
            return
        }

        interfaceController?.pop(to: CPNowPlayingTemplate.shared, animated: true) { didPop, error in
            Self.logTemplateFailure("pop to now playing", didSucceed: didPop, error: error)
        }
    }

    private func pushNowPlaying() {
        guard let interfaceController,
              !(interfaceController.topTemplate is CPNowPlayingTemplate)
        else {
            return
        }

        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { didPush, error in
            Self.logTemplateFailure("push now playing", didSucceed: didPush, error: error)
        }
    }

    /// CarPlay throws when a template operation fails with no completion handler,
    /// and the depth ceiling is the failure worth knowing about.
    ///
    /// Everything published here has to be free of listening history, so the
    /// operation is a compile-time constant and the framework's own error
    /// identity stands in for its message — a list title names a show the
    /// listener subscribes to, and a localized description can quote it.
    private static func logTemplateFailure(
        _ operation: StaticString,
        didSucceed: Bool,
        error: (any Error)?
    ) {
        guard !didSucceed else {
            return
        }

        let failure = error.map { $0 as NSError }
        logger.error(
            "CarPlay \(operation) failed: \(failure?.domain ?? "unknown", privacy: .public) \(failure?.code ?? 0)"
        )
    }

    private func presentPlaybackFailure() {
        guard let interfaceController else {
            return
        }

        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(
            CPAlertTemplate(titleVariants: ["Couldn't play this episode", "Couldn't play"], actions: [dismiss]),
            animated: true
        ) { didPresent, error in
            Self.logTemplateFailure("present playback failure", didSucceed: didPresent, error: error)
        }
    }
}
