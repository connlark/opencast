/// How the server proved it transcribed the device's exact audio bytes.
/// The worker emits `exactDeviceUpload` when the device's upload completed
/// (pass 2) and `serverDeviceHashMatch` otherwise.
nonisolated enum EpisodeRemoteTranscriptSourceMatchMode: String, Codable, Sendable {
    case serverDeviceHashMatch = "server_device_hash_match"
    case exactDeviceUpload = "exact_device_upload"
}
