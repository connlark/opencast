import Foundation

public enum EpisodeShareURL {
    public static func url(base: URL, payload: EpisodeSharePayload, startSeconds: Int? = nil) throws -> URL {
        let url = base.appending(path: try EpisodeShareTokenEncoder.token(for: payload))
        guard let startSeconds, startSeconds >= 1, startSeconds <= payload.maximumStartSeconds else {
            return url
        }
        return url.appending(queryItems: [URLQueryItem(name: "t", value: String(startSeconds))])
    }
}
