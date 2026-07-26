/// The single page of older rows a truncated list reaches through its
/// "Show More" row. A continuation never carries a marker of its own.
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
