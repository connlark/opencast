/// The raw value is the stored preference value.
nonisolated enum UpNextAutoAddLimitReachedAction: String, CaseIterable, Identifiable, Sendable {
    case stopAdding
    case addToTopOnly

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .stopAdding:
            "Stop Adding New Episodes"
        case .addToTopOnly:
            "Only Add to Top"
        }
    }

    var shortTitle: String {
        switch self {
        case .stopAdding:
            "Stop Adding"
        case .addToTopOnly:
            "Only Add to Top"
        }
    }
}
