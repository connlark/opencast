import SwiftData

extension EpisodeAdFreePassCoordinator {
    func enqueue(
        episode: EpisodeListItemSnapshot,
        origin: AdFreePassQueueOrigin,
        context: AdFreePassEnqueueContext,
        modelContext: ModelContext,
        transcriptionEngine: AdFreePassTranscriptionEngine = .productDefault,
        podcastLanguageCode: String?,
        mode: AdDetectionMode,
        prepareBackgroundSession: @escaping @MainActor () -> Void = {},
        refreshSkipZones: @escaping @MainActor () async -> Int
    ) {
        enqueue(
            episode: episode,
            origin: origin,
            downloads: context.downloads,
            transcriptionModels: context.transcriptionModels,
            appleSpeechAssets: context.appleSpeechAssets,
            transcriptions: context.transcriptions,
            adAnalyses: context.adAnalyses,
            modelContext: modelContext,
            transcriptionEngine: transcriptionEngine,
            podcastLanguageCode: podcastLanguageCode,
            mode: mode,
            remoteRunner: context.remoteRunner,
            remoteJobStore: context.remoteJobStore,
            remotePurchases: context.remotePurchases,
            prepareBackgroundSession: prepareBackgroundSession,
            refreshSkipZones: refreshSkipZones
        )
    }

    func restorePersistedQueue(
        resolveEpisode: (String) -> EpisodeListItemSnapshot?,
        context: AdFreePassEnqueueContext,
        modelContext: ModelContext,
        podcastLanguageCode: (String) -> String?,
        refreshSkipZones: @escaping @MainActor (EpisodeListItemSnapshot) async -> Int
    ) {
        restorePersistedQueue(
            resolveEpisode: resolveEpisode,
            downloads: context.downloads,
            transcriptionModels: context.transcriptionModels,
            appleSpeechAssets: context.appleSpeechAssets,
            transcriptions: context.transcriptions,
            adAnalyses: context.adAnalyses,
            modelContext: modelContext,
            podcastLanguageCode: podcastLanguageCode,
            remoteRunner: context.remoteRunner,
            remoteJobStore: context.remoteJobStore,
            remotePurchases: context.remotePurchases,
            refreshSkipZones: refreshSkipZones
        )
    }
}
