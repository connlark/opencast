import Foundation
import Intents
import OpenCastPlayback
import os
import SwiftData

final class SiriPlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    nonisolated private static let logger = Logger(
        subsystem: "com.connor.opencast",
        category: "SiriMedia"
    )

    private let appModel: OpenCastAppModel
    private let modelContext: ModelContext

    init(appModel: OpenCastAppModel, modelContext: ModelContext) {
        self.appModel = appModel
        self.modelContext = modelContext
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent
    ) async -> [INPlayMediaMediaItemResolutionResult] {
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        return mediaItemResolutionResults(for: await resolution(for: intent))
    }

    func confirm(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        let resolution = await resolution(for: intent)
        return Self.response(code: confirmationCode(for: resolution))
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        let resolution = await resolution(for: intent)
        guard let episode = episode(for: resolution) else {
            return Self.response(code: failureCode(for: resolution))
        }

        do {
            try appModel.playEpisode(
                episode,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
            if let playbackSpeed = intent.playbackSpeed {
                appModel.playback.setRate(Float(playbackSpeed))
            }
            guard appModel.playback.currentEpisode != nil else {
                Self.logger.error("Siri media playback returned without loaded content")
                return Self.response(code: .failure)
            }
            if case .failed(let message) = appModel.playback.state {
                Self.logger.error(
                    "Siri media playback entered a failed state: \(message, privacy: .private)"
                )
                return Self.response(code: .failure)
            }
            return Self.response(code: .success)
        } catch {
            Self.logger.error(
                "Siri media playback failed: \(error.localizedDescription, privacy: .private)"
            )
            return Self.response(code: .failure)
        }
    }

    func resolution(for intent: INPlayMediaIntent) async -> SiriMediaResolution {
        if let item = intent.mediaItems?.first, item.identifier != nil {
            return identifiedResolution(for: item) ?? .noMatch
        }
        if let container = intent.mediaContainer, container.identifier != nil {
            return identifiedResolution(for: container) ?? .noMatch
        }

        let subscriptions = appModel.library.subscriptions.map {
            SiriMediaSubscription(podcastID: $0.feedURL, title: $0.title)
        }
        let episodes = appModel.library.episodes
        return await SiriMediaResolver.resolve(
            mediaName: requestedMediaName(for: intent),
            mediaType: requestedMediaType(for: intent),
            subscriptions: subscriptions,
            episodes: episodes
        )
    }

    private func identifiedResolution(for item: INMediaItem?) -> SiriMediaResolution? {
        guard let item, let identifier = item.identifier else {
            return nil
        }

        switch item.type {
        case .podcastShow, .podcastPlaylist, .podcastStation:
            return appModel.library.isActivelySubscribed(to: identifier)
                ? .show(podcastID: identifier)
                : nil
        case .podcastEpisode:
            return appModel.episodeSnapshot(for: identifier) == nil
                ? nil
                : .episode(episodeID: identifier)
        default:
            if appModel.library.isActivelySubscribed(to: identifier) {
                return .show(podcastID: identifier)
            }
            return appModel.episodeSnapshot(for: identifier) == nil
                ? nil
                : .episode(episodeID: identifier)
        }
    }

    private func requestedMediaName(for intent: INPlayMediaIntent) -> String? {
        intent.mediaSearch?.mediaName
            ?? intent.mediaSearch?.artistName
            ?? intent.mediaSearch?.albumName
            ?? intent.mediaContainer?.title
            ?? intent.mediaItems?.first?.title
    }

    private func requestedMediaType(for intent: INPlayMediaIntent) -> INMediaItemType {
        if let mediaSearch = intent.mediaSearch, mediaSearch.mediaType != .unknown {
            return mediaSearch.mediaType
        }
        if let item = intent.mediaItems?.first {
            return item.type
        }
        return intent.mediaContainer?.type ?? .unknown
    }

    private func mediaItemResolutionResults(
        for resolution: SiriMediaResolution
    ) -> [INPlayMediaMediaItemResolutionResult] {
        switch resolution {
        case .show(let podcastID):
            guard let subscription = appModel.library.subscriptions.first(where: {
                $0.feedURL == podcastID
            }) else {
                return [.unsupported(forReason: .serviceUnavailable)]
            }
            let item = INMediaItem(
                identifier: podcastID,
                title: subscription.title,
                type: .podcastShow,
                artwork: nil,
                artist: nil
            )
            return [.success(with: item)]
        case .episode(let episodeID):
            guard let episode = appModel.episodeSnapshot(for: episodeID) else {
                return [.unsupported(forReason: .serviceUnavailable)]
            }
            let item = INMediaItem(
                identifier: episodeID,
                title: episode.title,
                type: .podcastEpisode,
                artwork: nil,
                artist: episode.podcastTitle
            )
            return [.success(with: item)]
        case .resume:
            return [.notRequired()]
        case .noMatch:
            return [.unsupported(forReason: .serviceUnavailable)]
        }
    }

    private func confirmationCode(
        for resolution: SiriMediaResolution
    ) -> INPlayMediaIntentResponseCode {
        episode(for: resolution) == nil ? failureCode(for: resolution) : .ready
    }

    private func failureCode(
        for resolution: SiriMediaResolution
    ) -> INPlayMediaIntentResponseCode {
        switch resolution {
        case .show, .resume:
            .failureNoUnplayedContent
        case .episode, .noMatch:
            .failure
        }
    }

    private func episode(for resolution: SiriMediaResolution) -> EpisodeListItemSnapshot? {
        switch resolution {
        case .show(let podcastID):
            PodcastPrimaryAction.resolve(
                episodes: appModel.library.episodes(forPodcastID: podcastID),
                library: appModel.library
            )?.episode
        case .episode(let episodeID):
            appModel.episodeSnapshot(for: episodeID)
        case .resume:
            restoredEpisode() ?? appModel.library.inboxEpisodes.first
        case .noMatch:
            nil
        }
    }

    private func restoredEpisode() -> EpisodeListItemSnapshot? {
        guard let episodeID = appModel.playback.currentEpisode?.id.rawValue else {
            return nil
        }
        return appModel.episodeSnapshot(for: episodeID)
    }

    nonisolated private static func response(
        code: INPlayMediaIntentResponseCode
    ) -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: code, userActivity: nil)
    }
}
