import Foundation

/// XMLParser has already decoded XML entities, so anything still entity-shaped is
/// publisher double-encoding (`&amp;amp;`).
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
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = numericEntityPattern.matches(in: value, range: range)
        guard !matches.isEmpty else { return value }

        // One forward pass: replacing each match in place moves the tail every time, which is quadratic.
        var decoded = ""
        decoded.reserveCapacity(value.utf8.count)
        var cursor = value.startIndex
        for match in matches {
            guard match.numberOfRanges == 2,
                  let entityRange = Range(match.range(at: 0), in: value),
                  let payloadRange = Range(match.range(at: 1), in: value)
            else {
                continue
            }

            let payload = value[payloadRange]
            let codePoint: UInt32? = payload.lowercased().hasPrefix("x")
                ? UInt32(payload.dropFirst(), radix: 16)
                : UInt32(payload, radix: 10)

            guard let codePoint, let scalar = UnicodeScalar(codePoint), isXMLValid(scalar) else {
                continue
            }
            decoded += value[cursor..<entityRange.lowerBound]
            decoded.unicodeScalars.append(scalar)
            cursor = entityRange.upperBound
        }
        decoded += value[cursor...]
        return decoded
    }

    /// XML 1.0 Char production. A decoded control scalar in a title would make the OPML
    /// export unreadable to any XML parser.
    private static func isXMLValid(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
            true
        default:
            false
        }
    }
}
