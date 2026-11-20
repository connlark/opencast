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
