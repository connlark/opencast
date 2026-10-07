import Foundation
import SwiftData

/// A named playlist, synced through the private CloudKit database. CloudKit
/// allows no unique constraints or required fields, so identity is a logical
/// UUID key that duplicate repair enforces, items refer to it by
/// `playlistID` rather than a relationship, and every field is defaulted or
/// optional.
@Model
final class PlaylistRecord {
    var playlistID: String = ""
    var name: String = ""
    var kindRawValue: String = "manual"
    /// The smart playlist's saved rule; nil for manual playlists.
    var ruleJSON: String?
    var hidesPlayed: Bool = false
    /// A `PlaylistTint` key assigned when a smart playlist is created; nil
    /// for manual playlists.
    var tintKey: String?
    var originRawValue: String = "user"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Stable per-record identity so duplicate repair picks the same winner on
    /// every device (smallest UUID wins).
    var dedupeUUID: String = ""

    init(
        playlistID: String = UUID().uuidString,
        name: String,
        kind: PlaylistKind = .manual,
        ruleJSON: String? = nil,
        hidesPlayed: Bool = false,
        tintKey: String? = nil,
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
        self.tintKey = tintKey
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
