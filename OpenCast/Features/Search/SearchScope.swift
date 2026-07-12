import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case library
    case discover

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .library:
            "Your Library"
        case .discover:
            "Discover"
        }
    }
}
