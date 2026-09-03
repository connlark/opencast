/// The store bundle every ad-free pass needs, built once by the app model
/// so enqueue and queue restore stop repeating the same argument list.
struct AdFreePassEnqueueContext {
    let downloads: DownloadStore
    let transcriptionModels: TranscriptionModelStore
    let appleSpeechAssets: AppleSpeechAssetStore
    let transcriptions: EpisodeTranscriptionStore
    let adAnalyses: EpisodeAdAnalysisStore
    // Cloud detect passes only; on-device items never touch these.
    let remoteRunner: RemoteTranscriptionJobRunner
    let remoteJobStore: RemoteTranscriptionJobStore
    let remotePurchases: RemoteTranscriptionPurchaseStore
}
