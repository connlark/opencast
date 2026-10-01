import SwiftUI

/// The palette a smart playlist draws its cover, glyph and glow tint from.
/// The raw value is stored in `PlaylistRecord.tintKey` at creation, so case
/// names are durable storage keys.
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

    /// The text color for a label on a prominent fill of this tint: white
    /// reads at about 2:1 on the light fills, black above 8:1.
    var prominentLabelColor: Color {
        switch self {
        case .orange, .yellow, .green, .teal:
            .black
        case .red, .blue, .indigo, .purple:
            .white
        }
    }

    /// Unknown or missing keys (a newer palette, a hand-inserted row) fall
    /// back to blue.
    static func resolved(_ key: String?) -> PlaylistTint {
        key.flatMap(PlaylistTint.init(rawValue:)) ?? .blue
    }

    /// Picks the tint the fewest existing playlists use so new smart
    /// playlists stay visually distinct; ties go to declaration order.
    /// Unknown keys in `used` are ignored.
    static func next(after used: [String]) -> PlaylistTint {
        allCases.min { lhs, rhs in
            used.count(where: { $0 == lhs.rawValue }) < used.count(where: { $0 == rhs.rawValue })
        } ?? .red
    }
}
