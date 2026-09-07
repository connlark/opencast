import Foundation

/// In-process link target for show-notes timestamps. The scheme never
/// leaves the app: `EpisodeShowNotesView` intercepts it through
/// `OpenURLAction` before the system URL router sees it.
enum ShowNotesTimestampLink {
    nonisolated private static let scheme = "opencast-shownotes"
    nonisolated private static let host = "seek"
    nonisolated private static let secondsQueryName = "t"

    nonisolated static func url(seconds: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: secondsQueryName, value: String(seconds))]
        return components.url
    }

    nonisolated static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == scheme,
              url.host() == host,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .first(where: { $0.name == secondsQueryName })?
                  .value,
              let seconds = TimeInterval(value),
              seconds.isFinite,
              seconds >= 0
        else {
            return nil
        }
        return seconds
    }
}
