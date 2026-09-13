import Foundation

nonisolated struct PerformanceState: Codable, Equatable, Sendable {
    enum Domain: String, Codable, CaseIterable, Sendable {
        case scene, playback, nowPlaying, transcription, compute, feed
        var identifier: String { "com.connor.opencast.\(rawValue)" }
        var labels: Set<String> {
            switch self {
            case .scene: ["foreground", "background"]
            case .playback: ["absent", "paused", "buffering", "playing"]
            case .nowPlaying: ["hidden", "presenting", "visible", "dismissing"]
            case .transcription: ["idle", "on-device", "remote"]
            case .compute: ["idle", "system-speech", "background-safe", "cpu", "neural-engine", "gpu"]
            case .feed: ["idle", "loading", "refreshing"]
            }
        }
    }

    let domain: Domain
    let label: String

    init?(domain: Domain, label: String) {
        guard domain.labels.contains(label) else { return nil }
        self.domain = domain
        self.label = label
    }
}
