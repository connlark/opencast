import Foundation

/// The two recap scopes the transcript menu offers. Both end at the playhead;
/// they differ in how far back they reach and how they are sampled.
nonisolated enum TranscriptRecapWindowKind: String, CaseIterable, Codable, Sendable {
    case lastFiveMinutes
    case soFar

    /// Below this playhead there is nothing worth recapping: the entry is
    /// disabled (last five minutes) or hidden (so far).
    var minimumPlayhead: TimeInterval {
        switch self {
        case .lastFiveMinutes: 30
        case .soFar: 15 * 60
        }
    }

    var menuTitle: String {
        switch self {
        case .lastFiveMinutes: "Recap the Last 5 Minutes"
        case .soFar: "Recap So Far"
        }
    }

    var title: String {
        switch self {
        case .lastFiveMinutes: "Last 5 Minutes"
        case .soFar: "So Far"
        }
    }
}
