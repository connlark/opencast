/// The raw value is persisted as a view preference.
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
