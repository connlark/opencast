/// One CarPlay list, already sliced to the head unit's ceilings.
nonisolated struct CarPlayBrowseSnapshot: Equatable, Sendable {
    let title: String
    let sections: [CarPlayListSection]
    let emptyTitleVariants: [String]
    let emptySubtitleVariants: [String]
    let showsSpinnerWhileEmpty: Bool
    let continuation: CarPlayListContinuation?

    var rowCount: Int {
        sections.reduce(0) { $0 + $1.rows.count }
    }
}
