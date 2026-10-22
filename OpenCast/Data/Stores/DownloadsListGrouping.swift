/// How the Downloads tab lists completed downloads. The raw value is a
/// stored preference value.
nonisolated enum DownloadsListGrouping: String, CaseIterable, Sendable {
    case flat
    case byShow
}
