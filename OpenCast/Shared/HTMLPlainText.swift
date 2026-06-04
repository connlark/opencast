import Foundation

enum HTMLPlainText {
    nonisolated static func collapsedText(from html: String) -> String {
        structuredText(from: html)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func structuredText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|svg|iframe|object|embed)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<figure\b[^>]*>.*?</figure>"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<(audio|video)\b[^>]*>.*?</\1>"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?i)<\s*br\s*/?\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<\s*hr\b[^>]*>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<\s*li\b[^>]*>"#, with: "\n- ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)</\s*(p|div|section|article|header|footer|blockquote|h[1-6]|li|tr|table|ul|ol)\s*>"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(in: text)
        text = improveTimelineSpacing(in: text)
        return normalizeLayout(in: text)
    }

    nonisolated private static func decodeEntities(in value: String) -> String {
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

    nonisolated private static func decodeEntitiesOnce(in value: String) -> String {
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
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacing("&\(entity);", with: replacement)
        }
        return decodeNumericEntities(in: decoded)
    }

    nonisolated private static func decodeNumericEntities(in value: String) -> String {
        let pattern = #"&#(x[0-9A-Fa-f]+|\d+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

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

    nonisolated private static func improveTimelineSpacing(in value: String) -> String {
        value
            .replacingOccurrences(
                of: #"(?<=[\p{L}\p{N}\)])(?=\d{1,2}:\d{2}\s*\p{Pd})"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b(\d{1,2}:\d{2})(?=[\p{L}])"#,
                with: "$1 ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b(\d{1,2}:\d{2})\s*(\p{Pd})\s*"#,
                with: "$1 $2 ",
                options: .regularExpression
            )
    }

    nonisolated private static func normalizeLayout(in value: String) -> String {
        value
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
            .replacing("\u{00A0}", with: " ")
            .replacingOccurrences(of: #"[ \t\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
