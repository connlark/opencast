/// Where Play Next / Play Last puts an episode, or a playlist's episodes, in
/// Up Next.
nonisolated enum UpNextQueuePosition: Sendable {
    case next
    case last
}
