import Foundation

enum NotificationPayload {
    static func artworkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let payload = userInfo["opencast"] as? [String: Any],
              payload["kind"] as? String == "episode",
              let artworkURLString = nonEmptyString(payload["artwork_url"]),
              let url = URL(string: artworkURLString),
              url.scheme?.lowercased() == "https"
        else {
            return nil
        }

        return url
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
