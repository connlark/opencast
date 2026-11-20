import SwiftUI

/// Case names are durable storage keys: the raw value is stored in `PlaylistRecord.tintKey`.
nonisolated enum PlaylistTint: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple

    var color: Color {
        switch self {
        case .red:
            .red
        case .orange:
            .orange
        case .yellow:
            .yellow
        case .green:
            .green
        case .teal:
            .teal
        case .blue:
            .blue
        case .indigo:
            .indigo
        case .purple:
            .purple
        }
    }

    /// White reads at about 2:1 on the light fills, black above 8:1.
    var prominentLabelColor: Color {
        switch self {
        case .orange, .yellow, .green, .teal:
            .black
        case .red, .blue, .indigo, .purple:
            .white
        }
    }

    static func resolved(_ key: String?) -> PlaylistTint {
        key.flatMap(PlaylistTint.init(rawValue:)) ?? .blue
    }

    static func next(after used: [String]) -> PlaylistTint {
        allCases.min { lhs, rhs in
            used.count(where: { $0 == lhs.rawValue }) < used.count(where: { $0 == rhs.rawValue })
        } ?? .red
    }
}
