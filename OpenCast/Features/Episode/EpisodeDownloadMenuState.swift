/// Visibility/enabled mapping for the shared context menu's Download action:
/// hidden once downloaded, disabled while downloading.
enum EpisodeDownloadMenuState: Equatable {
    case available
    case downloading
    case downloaded

    var showsDownloadAction: Bool {
        self != .downloaded
    }

    var isDownloadActionEnabled: Bool {
        self == .available
    }
}
