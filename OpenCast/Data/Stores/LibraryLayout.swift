/// The container the Library renders its shows in.
nonisolated enum LibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .list:
            "List"
        case .grid:
            "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            "list.bullet"
        case .grid:
            "square.grid.2x2"
        }
    }
}
