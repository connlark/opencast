/// Storage figures as the Downloads screens print them.
nonisolated enum DownloadsStorageText {
    /// "1 episode", "3 episodes".
    static func episodes(_ count: Int) -> String {
        count == 1 ? "1 episode" : "\(count) episodes"
    }

    static func size(_ byteCount: Int64) -> String {
        max(byteCount, 0).formatted(.byteCount(style: .file))
    }

    /// "3 episodes, 120 MB", the storage caption and summary rows.
    static func summary(episodeCount: Int, byteCount: Int64) -> String {
        "\(episodes(episodeCount)), \(size(byteCount))"
    }

    /// "3 episodes · 120 MB", under a show's title.
    static func showDetail(episodeCount: Int, byteCount: Int64) -> String {
        "\(episodes(episodeCount)) · \(size(byteCount))"
    }
}
