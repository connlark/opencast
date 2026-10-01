/// What the playlist name prompt is asking for: a name for a new manual or
/// smart playlist, or a new name for an existing one.
nonisolated struct PlaylistNamePromptRequest: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case create
        case createSmart
        case rename(playlistID: String)
    }

    let kind: Kind
    let initialName: String

    var id: String {
        switch kind {
        case .create:
            "create"
        case .createSmart:
            "create-smart"
        case .rename(let playlistID):
            "rename-\(playlistID)"
        }
    }

    var title: String {
        switch kind {
        case .create:
            "New Playlist"
        case .createSmart:
            "New Smart Playlist"
        case .rename:
            "Rename Playlist"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .create, .createSmart:
            "Create"
        case .rename:
            "Rename"
        }
    }

    static func create() -> PlaylistNamePromptRequest {
        PlaylistNamePromptRequest(kind: .create, initialName: "")
    }

    static func createSmart() -> PlaylistNamePromptRequest {
        PlaylistNamePromptRequest(kind: .createSmart, initialName: "")
    }

    static func rename(_ playlist: PlaylistSummary) -> PlaylistNamePromptRequest {
        PlaylistNamePromptRequest(kind: .rename(playlistID: playlist.playlistID), initialName: playlist.name)
    }
}
