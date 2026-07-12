struct SearchSessionTaskKey: Equatable, Sendable {
    let scope: SearchScope
    let request: EpisodeSearchRequestKey
}
