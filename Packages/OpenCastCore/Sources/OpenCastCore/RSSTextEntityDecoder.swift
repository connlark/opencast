import Foundation

/// Bounded decode of leftover HTML entities in short display fields (titles,
/// authors) at parse time. XMLParser already performed the XML-level decode,
/// so anything still entity-shaped is publisher double-encoding
/// (`&amp;amp;` → `&amp;` → `&`). Mirrors the app-side show-notes clean
/// pass's three-iteration bound.
enum RSSTextEntityDecoder {
    static func decoded(_ value: String) -> String {
        guard value.contains("&") else {
            return value
        }
        var decoded = value
        for _ in 0..<3 {
            let next = decodeOnce(decoded)
            if next == decoded {
                break
            }
            decoded = next
        }
        return decoded
    }

    private static let namedEntities = [
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

    private static let numericEntityPattern = try! NSRegularExpression(
        pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#
    )

    private static func decodeOnce(_ value: String) -> String {
        var decoded = value
        for (entity, replacement) in namedEntities {
            // replacingOccurrences: the package's macOS 12 floor predates
            // String.replacing(_:with:).
            decoded = decoded.replacingOccurrences(of: "&\(entity);", with: replacement)
        }
        return decodeNumericEntities(decoded)
    }

    private static func decodeNumericEntities(_ value: String) -> String {
        var decoded = value
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in numericEntityPattern.matches(in: value, range: range).reversed() {
            guard match.numberOfRanges == 2,
                  let entityRange = Range(match.range(at: 0), in: decoded),
                  let payloadRange = Range(match.range(at: 1), in: decoded)
            else {
                continue
            }

            let payload = String(decoded[payloadRange])
            let codePoint: UInt32? = payload.lowercased().hasPrefix("x")
                ? UInt32(payload.dropFirst(), radix: 16)
                : UInt32(payload, radix: 10)

            if let codePoint, let scalar = UnicodeScalar(codePoint), isXMLValid(scalar) {
                decoded.replaceSubrange(entityRange, with: String(scalar))
            }
        }
        return decoded
    }

    /// XML 1.0 Char production. A double-encoded control entity (`&amp;#0;`)
    /// must not put a NUL/control scalar into a title — OPML export writes
    /// titles literally, and no XML parser (including reimport) accepts them.
    private static func isXMLValid(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
            true
        default:
            false
        }
    }
}
