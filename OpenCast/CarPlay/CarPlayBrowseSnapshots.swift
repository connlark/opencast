/// The three tab-root lists, built together so one observation pass covers
/// everything the car shows without drilling in.
nonisolated struct CarPlayBrowseSnapshots: Equatable, Sendable {
    let inbox: CarPlayBrowseSnapshot
    let library: CarPlayBrowseSnapshot
    let downloads: CarPlayBrowseSnapshot
}
