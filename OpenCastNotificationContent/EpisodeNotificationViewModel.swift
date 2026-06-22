import Foundation
import UIKit
import UserNotifications

struct EpisodeNotificationViewModel {
    let podcastTitle: String
    let episodeTitle: String
    let durationText: String?
    let summaryText: String?
    let artworkImage: UIImage?

    init(notification: UNNotification) {
        self.init(content: notification.request.content)
    }

    init(content: UNNotificationContent) {
        let payload = Self.opencastPayload(from: content.userInfo)
        let resolvedPodcastTitle = Self.nonEmptyString(content.title)
            ?? Self.nonEmptyString(payload?["podcast_title"])
            ?? "OpenCast"
        let resolvedEpisodeTitle = Self.nonEmptyString(content.subtitle)
            ?? Self.nonEmptyString(payload?["episode_title"])
            ?? "New episode"
        let legacyBody = Self.legacyBodyParts(from: content.body)

        podcastTitle = resolvedPodcastTitle
        episodeTitle = resolvedEpisodeTitle
        durationText = Self.normalizedDurationText(Self.nonEmptyString(payload?["episode_duration_text"]))
            ?? legacyBody.durationText
        summaryText = Self.payloadSummaryText(payload?["episode_summary"], episodeTitle: resolvedEpisodeTitle)
            ?? Self.legacySummaryText(legacyBody.summarySource, episodeTitle: resolvedEpisodeTitle)
        artworkImage = content.attachments.first.flatMap(Self.image)
    }

    var accessibilityLabel: String {
        [podcastTitle, episodeTitle, durationText, summaryText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var podcastInitials: String {
        if podcastTitle == "OpenCast" {
            return "OC"
        }

        let initials = podcastTitle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return initials.isEmpty ? "OC" : initials
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

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : collapseWhitespace(trimmed)
    }

    private static let orphanPunctuation = CharacterSet(charactersIn: "\"',;:-_|/\\()[]{}")
        .union(.whitespacesAndNewlines)

    private static func legacyBodyParts(from body: String) -> (durationText: String?, summarySource: String?) {
        let lines = body
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else {
            return (nil, nil)
        }

        let durationText = normalizedDurationText(firstLine)
        let summarySource = if durationText != nil {
            lines.dropFirst().joined(separator: " ")
        } else {
            lines.joined(separator: " ")
        }

        return (durationText, nonEmptyString(summarySource))
    }

    private static func legacySummaryText(_ value: String?, episodeTitle: String) -> String? {
        guard let value else {
            return nil
        }

        let decoded = decodeHTMLEntitiesUntilStable(value)
        let withoutTags = stripHTMLTags(decoded)
        let withoutDebris = removeURLAndAttributeDebris(withoutTags)
        let cleaned = trimOrphanPunctuation(collapseWhitespace(withoutDebris))
        guard isUsefulSummary(cleaned, episodeTitle: episodeTitle) else {
            return nil
        }
        return cleaned
    }

    private static func normalizedDurationText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = collapseWhitespace(value).uppercased()
        let pattern = #"^\d+ (MIN|HR)( \d+ MIN)?$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func payloadSummaryText(_ value: Any?, episodeTitle: String) -> String? {
        guard let value = nonEmptyString(value) else {
            return nil
        }

        guard isUsefulSummary(value, episodeTitle: episodeTitle) else {
            return nil
        }
        return value
    }

    private static func isUsefulSummary(_ value: String, episodeTitle: String) -> Bool {
        !value.isEmpty
            && value != "New episode available"
            && !titlesMatch(value, episodeTitle)
            && !isURLOnly(value)
    }

    private static func stripHTMLTags(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        var inTag = false
        for character in value {
            switch character {
            case "<":
                inTag = true
                output.append(" ")
            case ">":
                inTag = false
                output.append(" ")
            case _ where !inTag:
                output.append(character)
            default:
                break
            }
        }
        return output
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";")
            else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }

            let entityStart = value.index(after: index)
            let entity = String(value[entityStart..<semicolon])
            if let decoded = decodeEntity(entity) {
                output.append(decoded)
            } else {
                output.append(contentsOf: value[index...semicolon])
            }
            index = value.index(after: semicolon)
        }

        return output
    }

    private static func decodeHTMLEntitiesUntilStable(_ value: String) -> String {
        var current = value
        for _ in 0..<2 {
            let decoded = decodeHTMLEntities(current)
            if decoded == current {
                break
            }
            current = decoded
        }
        return current
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity {
        case "amp": "&"
        case "quot": "\""
        case "apos": "'"
        case "lt": "<"
        case "gt": ">"
        case "nbsp": " "
        case "ndash", "mdash": "-"
        case "lsquo", "rsquo": "'"
        case "ldquo", "rdquo": "\""
        case "hellip": "."
        default: decodeNumericEntity(entity)
        }
    }

    private static func decodeNumericEntity(_ entity: String) -> Character? {
        let scalarValue: UInt32?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            scalarValue = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            scalarValue = UInt32(entity.dropFirst())
        } else {
            scalarValue = nil
        }

        return scalarValue
            .flatMap(Unicode.Scalar.init)
            .map(Character.init)
    }

    private static func removeURLAndAttributeDebris(_ value: String) -> String {
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        var output: [String] = []
        var removedLinkDebris = false
        var index = 0
        while index < tokens.count {
            let token = stripMalformedParagraphPrefix(tokens[index])
            let normalized = trimOrphanPunctuation(token).lowercased()
            let next = tokens.indices.contains(index + 1)
                ? trimOrphanPunctuation(stripMalformedParagraphPrefix(tokens[index + 1])).lowercased()
                : nil

            if isHTMLTagMarker(normalized) {
                index += 1
                continue
            }
            if isAttributeToken(normalized)
                || isURLLike(normalized)
                || (normalized == "a" && next.map { isAttributeToken($0) } == true) {
                removedLinkDebris = true
                index += 1
                continue
            }

            output.append(token)
            index += 1
        }

        let joined = output.joined(separator: " ")
        return removedLinkDebris ? trimTrailingLinkPrompt(joined) : joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMalformedParagraphPrefix(_ token: String) -> String {
        for prefix in ["/p", "p"] {
            guard token.hasPrefix(prefix) else {
                continue
            }
            let rest = token.dropFirst(prefix.count)
            if let first = rest.first,
               first.isUppercase,
               rest.dropFirst().first?.isLowercase == true {
                return String(rest)
            }
        }
        return token
    }

    private static func isHTMLTagMarker(_ value: String) -> Bool {
        ["p", "/p", "br", "/br", "/a"].contains(value)
    }

    private static func isAttributeToken(_ value: String) -> Bool {
        value.hasPrefix("href=")
            || value.hasPrefix("src=")
            || value.hasPrefix("target=")
            || value.hasPrefix("rel=")
    }

    private static func isURLLike(_ value: String) -> Bool {
        let value = trimOrphanPunctuation(value).lowercased()
        return value.hasPrefix("http://")
            || value.hasPrefix("https://")
            || value.hasPrefix("www.")
            || value.contains("://")
    }

    private static func isURLOnly(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: \.isWhitespace)
        return tokens.count == 1 && tokens.first.map { isURLLike(String($0)) } == true
    }

    private static func trimTrailingLinkPrompt(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prompt in ["Visit", "Read more", "Learn more", "Listen now", "Subscribe"] {
            if value == prompt {
                value.removeAll()
                break
            }

            let suffix = " \(prompt)"
            if value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                break
            }
        }
        return value
    }

    private static func trimOrphanPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: orphanPunctuation)
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        collapseWhitespace(lhs).lowercased() == collapseWhitespace(rhs).lowercased()
    }

    private static func image(from attachment: UNNotificationAttachment) -> UIImage? {
        let url = attachment.url
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return UIImage(contentsOfFile: url.path)
    }
}
