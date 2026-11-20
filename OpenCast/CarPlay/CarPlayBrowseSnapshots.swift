nonisolated struct CarPlayBrowseSnapshots: Equatable, Sendable {
    let inbox: CarPlayBrowseSnapshot
    let library: CarPlayBrowseSnapshot
    let downloads: CarPlayBrowseSnapshot
}
