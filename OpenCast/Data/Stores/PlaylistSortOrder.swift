/// How the playlist collection is ordered. The raw value is persisted as a
/// view preference, never on the playlist rows.
nonisolated enum PlaylistSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
    case name
    case recentlyUpdated

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .name:
            "Name"
        case .recentlyUpdated:
            "Recently Updated"
        }
    }
}
