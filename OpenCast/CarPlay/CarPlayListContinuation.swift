/// A continuation never carries a "Show More" row of its own.
nonisolated struct CarPlayListContinuation: Equatable, Sendable {
    let title: String
    let sections: [CarPlayListSection]

    var snapshot: CarPlayBrowseSnapshot {
        CarPlayBrowseSnapshot(
            title: title,
            sections: sections,
            emptyTitleVariants: [],
            emptySubtitleVariants: [],
            showsSpinnerWhileEmpty: false,
            continuation: nil
        )
    }
}
