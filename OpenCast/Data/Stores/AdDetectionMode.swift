/// Where a Detect Ads pass runs: fully on this device (free) or as a cloud
/// job that transcribes server-side and chains ad detection (uses
/// transcription credits, delivers the transcript too). Also the per-queue-
/// item mode on `AdFreePassQueueItem`.
nonisolated enum AdDetectionMode: String, Codable, Sendable, Equatable {
    case onDevice
    case cloud
}
