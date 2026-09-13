import Foundation

nonisolated enum ResumeWidgetRoute {
    static func action(for url: URL) -> OpenCastSystemAction? {
        guard url.scheme == "opencast", url.host == "resume", url.path.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.count == 1,
              let item = components.queryItems?.first, item.name == "episode",
              let id = item.value, !id.isEmpty, id.count <= 512
        else { return nil }
        return .playEpisode(id)
    }
}
