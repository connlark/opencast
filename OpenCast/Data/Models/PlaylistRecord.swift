import Foundation
import SwiftData

/// A named playlist. Device-local today but shaped for CloudKit: a logical
/// UUID key instead of a unique constraint, no relationships (items refer to
/// it by `playlistID`), and every field defaulted or optional.
@Model
final class PlaylistRecord {
    var playlistID: String = ""
    var name: String = ""
    var kindRawValue: String = "manual"
    /// The smart playlist's saved rule; nil for manual playlists.
    var ruleJSON: String?
    var hidesPlayed: Bool = false
    /// Reserved for a user-chosen playlist order; the collection sorts by
    /// preference today.
    var sortKey: String = ""
    /// A `PlaylistTint` key assigned when a smart playlist is created; nil
    /// for manual playlists.
    var tintKey: String?
    /// Reserved for a custom cover glyph; nil renders the default.
    var symbolName: String?
    var originRawValue: String = "user"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Stable per-record identity so duplicate repair picks the same winner on
    /// every device once playlists sync (smallest UUID wins).
    var dedupeUUID: String = ""

    init(
        playlistID: String = UUID().uuidString,
        name: String,
        kind: PlaylistKind = .manual,
        ruleJSON: String? = nil,
        hidesPlayed: Bool = false,
        sortKey: String = "",
        tintKey: String? = nil,
        symbolName: String? = nil,
        origin: PlaylistOrigin = .user,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        dedupeUUID: String = UUID().uuidString
    ) {
        self.playlistID = playlistID
        self.name = name
        kindRawValue = kind.rawValue
        self.ruleJSON = ruleJSON
        self.hidesPlayed = hidesPlayed
        self.sortKey = sortKey
        self.tintKey = tintKey
        self.symbolName = symbolName
        originRawValue = origin.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dedupeUUID = dedupeUUID
    }

    var kind: PlaylistKind {
        get {
            PlaylistKind(rawValue: kindRawValue) ?? .manual
        }
        set {
            kindRawValue = newValue.rawValue
        }
    }

    var origin: PlaylistOrigin {
        get {
            PlaylistOrigin(rawValue: originRawValue) ?? .user
        }
        set {
            originRawValue = newValue.rawValue
        }
    }
}
