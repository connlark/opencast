import Foundation

nonisolated enum TranscriptRecapWindowKind: String, CaseIterable, Codable, Sendable {
    case lastFiveMinutes
    case soFar

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
