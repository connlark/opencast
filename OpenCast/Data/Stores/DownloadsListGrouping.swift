/// Raw values are stored preference values; never change them.
nonisolated enum DownloadsListGrouping: String, CaseIterable, Sendable {
    case flat
    case byShow
}
