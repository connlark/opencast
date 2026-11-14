import Foundation

public enum HTMLPlainText {
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    private static let comments = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->"#)
    private static let hiddenElements = try! NSRegularExpression(pattern: #"(?is)<(script|style|noscript|svg|iframe|object|embed)\b[^>]*>.*?</\1>"#)
    private static let figures = try! NSRegularExpression(pattern: #"(?is)<figure\b[^>]*>.*?</figure>"#)
    private static let mediaElements = try! NSRegularExpression(pattern: #"(?is)<(audio|video)\b[^>]*>.*?</\1>"#)
    private static let lineBreaks = try! NSRegularExpression(pattern: #"(?i)<\s*br\s*/?\s*>"#)
    private static let horizontalRules = try! NSRegularExpression(pattern: #"(?i)<\s*hr\b[^>]*>"#)
    private static let listItems = try! NSRegularExpression(pattern: #"(?i)<\s*li\b[^>]*>"#)
    private static let blockClosings = try! NSRegularExpression(pattern: #"(?i)</\s*(p|div|section|article|header|footer|blockquote|h[1-6]|li|tr|table|ul|ol)\s*>"#)
    private static let tags = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let joinedTimelineEntries = try! NSRegularExpression(pattern: #"(?<=[\p{L}\p{Nl}\p{No}\)])(?=\d{1,2}:\d{2}\s*\p{Pd})"#)
    private static let joinedTimestampWords = try! NSRegularExpression(pattern: #"\b(\d{1,2}:\d{2})(?=[\p{L}])"#)
    private static let timelineDashes = try! NSRegularExpression(pattern: #"\b(\d{1,2}:\d{2})\s*(\p{Pd})\s*"#)
    private static let horizontalWhitespace = try! NSRegularExpression(pattern: #"[ \t\f]+"#)
    private static let newlinePadding = try! NSRegularExpression(pattern: #" *\n *"#)
    private static let repeatedNewlines = try! NSRegularExpression(pattern: #"\n{3,}"#)

    public static func collapsedText(from html: String) -> String {
        structuredText(from: html)
            .replacingMatches(of: Self.whitespace, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func structuredText(from html: String) -> String {
        var text = html
        if text.contains("<") {
            text = text.replacingMatches(of: Self.comments, with: " ")
            text = text.replacingMatches(of: Self.hiddenElements, with: " ")
            text = text.replacingMatches(of: Self.figures, with: "\n\n")
            text = text.replacingMatches(of: Self.mediaElements, with: "\n\n")
            text = text.replacingMatches(of: Self.lineBreaks, with: "\n")
            text = text.replacingMatches(of: Self.horizontalRules, with: "\n\n")
            text = text.replacingMatches(of: Self.listItems, with: "\n- ")
            text = text.replacingMatches(of: Self.blockClosings, with: "\n\n")
            text = text.replacingMatches(of: Self.tags, with: " ")
        }
        text = decodeEntities(in: text)
        text = improveTimelineSpacing(in: text)
        return normalizeLayout(in: text)
    }

    public static func decodeEntities(in value: String) -> String {
        guard value.contains("&") else { return value }
        var decoded = value
        for _ in 0..<3 {
            let next = decodeEntitiesOnce(in: decoded)
            if next == decoded {
                break
            }
            decoded = next
        }
        return decoded
    }

    private static func decodeEntitiesOnce(in value: String) -> String {
        let namedEntities = [
            "amp": "&",
            "quot": "\"",
            "apos": "'",
            "lt": "<",
            "gt": ">",
            "nbsp": " ",
            "ndash": "\u{2013}",
            "mdash": "\u{2014}",
            "lsquo": "\u{2018}",
            "rsquo": "\u{2019}",
            "ldquo": "\u{201C}",
            "rdquo": "\u{201D}",
            "hellip": "\u{2026}",
            "copy": "\u{00A9}",
            "reg": "\u{00AE}"
        ]
        var decoded = value
        // Large-show-note profiling covers this Foundation bulk-replacement
        // path; keep it despite the house preference for String.replacing.
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: "&\(entity);", with: replacement)
        }
        return decodeNumericEntities(in: decoded)
    }

    private static let numericEntityPattern = try! NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#)

    private static func decodeNumericEntities(in value: String) -> String {
        guard value.contains("&#") else { return value }
        let regex = numericEntityPattern

        var decoded = value
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: range).reversed() {
            guard match.numberOfRanges == 2,
                  let entityRange = Range(match.range(at: 0), in: decoded),
                  let payloadRange = Range(match.range(at: 1), in: decoded)
            else {
                continue
            }

            let payload = String(decoded[payloadRange])
            let codePoint: UInt32?
            if payload.lowercased().hasPrefix("x") {
                codePoint = UInt32(payload.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(payload, radix: 10)
            }

            if let codePoint,
               let scalar = UnicodeScalar(codePoint) {
                decoded.replaceSubrange(entityRange, with: String(scalar))
            }
        }

        return decoded
    }

    private static func improveTimelineSpacing(in value: String) -> String {
        guard value.contains(":") else { return value }
        return value
            .replacingMatches(of: Self.joinedTimelineEntries, with: " ")
            .replacingMatches(of: Self.joinedTimestampWords, with: "$1 ")
            .replacingMatches(of: Self.timelineDashes, with: "$1 $2 ")
    }

    private static func normalizeLayout(in value: String) -> String {
        // This normalization is part of the same measured large-note path.
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingMatches(of: Self.horizontalWhitespace, with: " ")
            .replacingMatches(of: Self.newlinePadding, with: "\n")
            .replacingMatches(of: Self.repeatedNewlines, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private extension String {
    func replacingMatches(of expression: NSRegularExpression, with template: String) -> String {
        expression.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
