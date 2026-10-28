/// What Auto Add to Up Next does once Up Next holds the limit. The raw
/// value is the stored preference value.
nonisolated enum UpNextAutoAddLimitReachedAction: String, CaseIterable, Identifiable, Sendable {
    /// Leaves every further new episode out.
    case stopAdding
    /// A show set to Top replaces the last queued row with its new episode;
    /// shows set to Bottom wait until Up Next is below the limit.
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
