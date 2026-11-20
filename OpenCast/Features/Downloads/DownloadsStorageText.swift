nonisolated enum DownloadsStorageText {
    static func episodes(_ count: Int) -> String {
        count == 1 ? "1 episode" : "\(count) episodes"
    }

    static func size(_ byteCount: Int64) -> String {
        max(byteCount, 0).formatted(.byteCount(style: .file))
    }

    static func summary(episodeCount: Int, byteCount: Int64) -> String {
        "\(episodes(episodeCount)), \(size(byteCount))"
    }

    static func showDetail(episodeCount: Int, byteCount: Int64) -> String {
        "\(episodes(episodeCount)) · \(size(byteCount))"
    }
}
