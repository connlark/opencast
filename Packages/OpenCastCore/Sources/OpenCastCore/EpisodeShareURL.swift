import Foundation

/// A share link: the base plus the token as the last path component, and the
/// start time as `?t=<seconds>` outside the token so a recipient can edit it.
/// A start the page would ignore is left off.
public enum EpisodeShareURL {
    public static func url(base: URL, payload: EpisodeSharePayload, startSeconds: Int? = nil) throws -> URL {
        let url = base.appending(path: try EpisodeShareTokenEncoder.token(for: payload))
        guard let startSeconds, startSeconds >= 1, startSeconds <= payload.maximumStartSeconds else {
            return url
        }
        return url.appending(queryItems: [URLQueryItem(name: "t", value: String(startSeconds))])
    }
}
