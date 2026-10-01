/// How playing a playlist meets the existing Up Next queue: `replace` clears
/// it and starts the first episode; `addAfter` appends behind it and starts
/// only when nothing is loaded.
nonisolated enum PlaylistPlayMode: Sendable {
    case replace
    case addAfter
}
