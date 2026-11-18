import Foundation
import SwiftData

/// Detect Ads in New Episodes: what the trigger reads to qualify an episode,
/// and the enqueue it asks for.
extension OpenCastAppModel {
    /// The enqueue context and the skip zone coordinator are private to the
    /// app model's main file, which passes them in.
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
                // No background session is armed: the card needs the
                // listener's own tap.
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

    /// At launch once the ad detection queue is restored, and on each
    /// activation.
    func sweepNewEpisodeAdDetection(modelContext: ModelContext) {
        newEpisodeAdDetection.sweep(modelContext: modelContext)
    }
}
