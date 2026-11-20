enum AppSection: String, CaseIterable, Identifiable {
    case library
    case playlists
    case upNext
    case inbox
    case downloads
    case settings
    case search

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .library:
            "Library"
        case .playlists:
            "Playlists"
        case .upNext:
            "Up Next"
        case .inbox:
            "Inbox"
        case .downloads:
            "Downloads"
        case .settings:
            "Settings"
        case .search:
            "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            "books.vertical"
        case .playlists:
            "list.bullet.rectangle"
        case .upNext:
            "play.square.stack"
        case .inbox:
            "tray"
        case .downloads:
            "square.and.arrow.down"
        case .settings:
            "gearshape"
        case .search:
            "magnifyingglass"
        }
    }
}
