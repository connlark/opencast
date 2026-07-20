/// How the server proved it transcribed the device's exact audio bytes.
/// Pass 0 only produces `serverDeviceHashMatch`; the exact-device upload
/// fallback arrives in a later pass.
nonisolated enum EpisodeRemoteTranscriptSourceMatchMode: String, Codable, Sendable {
    case serverDeviceHashMatch = "server_device_hash_match"
    case exactDeviceUpload = "exact_device_upload"
}
