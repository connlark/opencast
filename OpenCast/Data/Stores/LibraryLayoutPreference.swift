/// The stored Library layout choice. Automatic follows the window: a grid in
/// regular width, a list in compact width.
nonisolated enum LibraryLayoutPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case list
    case grid

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .list:
            LibraryLayout.list.title
        case .grid:
            LibraryLayout.grid.title
        }
    }

    var systemImage: String {
        switch self {
        case .automatic:
            "rectangle.3.group"
        case .list:
            LibraryLayout.list.systemImage
        case .grid:
            LibraryLayout.grid.systemImage
        }
    }

    func resolved(isRegularWidth: Bool) -> LibraryLayout {
        switch self {
        case .automatic:
            isRegularWidth ? .grid : .list
        case .list:
            .list
        case .grid:
            .grid
        }
    }
}
