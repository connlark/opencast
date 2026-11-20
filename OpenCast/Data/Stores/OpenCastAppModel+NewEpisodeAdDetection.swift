import Foundation
import SwiftData

extension OpenCastAppModel {
    func makeNewEpisodeAdDetection(
        enqueueContext: AdFreePassEnqueueContext,
        skipZones: PlaybackSkipZoneCoordinator
    ) -> NewEpisodeAdDetectionCoordinator {
        NewEpisodeAdDetectionCoordinator(
            settings: downloadSettings,
            downloadRecord: { [downloads] episodeID in
                downloads.record(for: episodeID)
            },
            hasDownloadedFile: { [downloads] record in
                downloads.downloadedFileExists(for: record)
            },
            episode: { [library] episodeID in
                library.episode(with: episodeID)
            },
            releasedEpisodes: { [library] podcastID in
                library.releasedEpisodes(forPodcastID: podcastID, publishedAfter: .distantPast, asOf: .now)
            },
            isPlayedOrArchived: { [library] episodeID in
                library.progressRecord(for: episodeID)?.isPlayed == true
                    || library.isArchived(episodeID: episodeID)
            },
            queueStatus: { [adFreePass] episodeID in
                adFreePass.queueStatus(for: episodeID)
            },
            isQueueRestored: { [weak self] in
                self?.hasRestoredPlaybackSurface ?? false
            },
            enqueue: { [weak self, adFreePass] request, modelContext in
                adFreePass.enqueue(
                    episode: request.episode,
                    origin: request.origin,
                    context: enqueueContext,
                    modelContext: modelContext,
                    podcastLanguageCode: self?.podcastLanguageCode(forPodcastID: request.episode.podcastID),
                    mode: request.mode,
                    presentsKeyScreen: request.presentsKeyScreen,
                    refreshSkipZones: {
                        await skipZones.zoneCountAfterPass(for: request.episode)
                    }
                )
            }
        )
    }

    func sweepNewEpisodeAdDetection(modelContext: ModelContext) {
        newEpisodeAdDetection.sweep(modelContext: modelContext)
    }
}
