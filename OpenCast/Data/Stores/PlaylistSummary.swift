import Foundation

nonisolated struct PlaylistSummary: Identifiable, Equatable, Sendable {
    let playlistID: String
    var name: String
    let kind: PlaylistKind
    var ruleJSON: String?
    /// A smart playlist's decoded rule: the default rule when none is
    /// stored, nil when the stored rule is unreadable (a newer version).
    /// Always nil for a manual playlist.
    var rule: PlaylistRule?
    var hidesPlayed: Bool
    var tintKey: String?
    var symbolName: String?
    let origin: PlaylistOrigin
    var itemCount: Int
    /// Sum of the items' stored fallback durations; items without one add
    /// nothing.
    var totalDuration: TimeInterval
    let createdAt: Date
    var updatedAt: Date
    /// Up to four distinct shows in item order, for the mosaic cover.
    var coverPodcastIDs: [String]

    var id: String {
        playlistID
    }

    var hasUnreadableRule: Bool {
        kind == .smart && rule == nil
    }

    var tint: PlaylistTint? {
        kind == .smart ? PlaylistTint.resolved(tintKey) : nil
    }
}
