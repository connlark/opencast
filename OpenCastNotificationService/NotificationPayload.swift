import Foundation

enum NotificationPayload {
    static func artworkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        artworkURL(named: "artwork_url", from: userInfo)
    }

    static func episodeArtworkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        artworkURL(named: "episode_artwork_url", from: userInfo)
    }

    private static func artworkURL(named field: String, from userInfo: [AnyHashable: Any]) -> URL? {
        guard let payload = opencastPayload(from: userInfo),
              payload["kind"] as? String == "episode",
              let artworkURLString = nonEmptyString(payload[field]),
              let url = URL(string: artworkURLString),
              Self.isSupportedArtworkScheme(url.scheme)
        else {
            return nil
        }

        return url
    }

    private static func opencastPayload(from userInfo: [AnyHashable: Any]) -> [String: Any]? {
        if let payload = userInfo["opencast"] as? [String: Any] {
            return payload
        }
        if let payload = userInfo["opencast"] as? NSDictionary {
            return payload as? [String: Any]
        }
        return nil
    }

    private static func isSupportedArtworkScheme(_ scheme: String?) -> Bool {
        switch scheme?.lowercased() {
        case "http", "https":
            true
        default:
            false
        }
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
