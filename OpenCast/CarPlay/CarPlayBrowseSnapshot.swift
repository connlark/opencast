/// One CarPlay list, already sliced to the head unit's ceilings: the rows to
/// render, the empty-state copy to show when there are none, and the single
/// continuation page a "Show More" row reaches.
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
