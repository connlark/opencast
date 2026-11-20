struct AdFreePassEnqueueContext {
    let downloads: DownloadStore
    let transcriptionModels: TranscriptionModelStore
    let appleSpeechAssets: AppleSpeechAssetStore
    let transcriptions: EpisodeTranscriptionStore
    let adAnalyses: EpisodeAdAnalysisStore
    let remoteRunner: RemoteTranscriptionJobRunner
    let remoteJobStore: RemoteTranscriptionJobStore
    let remotePurchases: RemoteTranscriptionPurchaseStore
}
