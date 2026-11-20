/// How the server proved it transcribed the device's exact audio bytes.
nonisolated enum EpisodeRemoteTranscriptSourceMatchMode: String, Codable, Sendable {
    case serverDeviceHashMatch = "server_device_hash_match"
    case exactDeviceUpload = "exact_device_upload"
}
