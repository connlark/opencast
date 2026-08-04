import CoreFoundation
import Foundation

enum RSSFeedRecovery {
    private static let xmlEncodingPattern = try! NSRegularExpression(
        pattern: #"<\?xml[^>]*\bencoding\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    private static let invalidAmpersandPattern = try! NSRegularExpression(
        pattern: #"&(?!(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);)"#
    )
    private static let namedEntityPattern = try! NSRegularExpression(
        pattern: #"&([a-zA-Z][a-zA-Z0-9]*);"#
    )
    private static let commonHTMLEntities = [
        "nbsp": "&#160;",
        "ndash": "&#8211;",
        "mdash": "&#8212;",
        "lsquo": "&#8216;",
        "rsquo": "&#8217;",
        "ldquo": "&#8220;",
        "rdquo": "&#8221;",
        "hellip": "&#8230;"
    ]
    private static let xmlNamedEntities = ["amp", "apos", "gt", "lt", "quot"]

    static func recoveredData(from data: Data) -> Data? {
        guard let decodedXML = decodedXML(from: data) else {
            return nil
        }

        var xml = recoverEntities(in: decodedXML)
        normalizeEncodingDeclaration(in: &xml)
        return xml.data(using: .utf8)
    }

    private static func recoverEntities(in xml: String) -> String {
        var recovered = ""
        var start = xml.startIndex

        while
            let cdataStart = xml.range(
                of: "<![CDATA[",
                range: start..<xml.endIndex
            )
        {
            recovered += recoverEntities(inFragment: String(xml[start..<cdataStart.lowerBound]))
            guard
                let cdataEnd = xml.range(
                    of: "]]>",
                    range: cdataStart.upperBound..<xml.endIndex
                )
            else {
                recovered += xml[cdataStart.lowerBound...]
                return recovered
            }

            recovered += xml[cdataStart.lowerBound..<cdataEnd.upperBound]
            start = cdataEnd.upperBound
        }

        recovered += recoverEntities(inFragment: String(xml[start...]))
        return recovered
    }

    private static func recoverEntities(inFragment fragment: String) -> String {
        var recovered = invalidAmpersandPattern.stringByReplacingMatches(
            in: fragment,
            range: NSRange(fragment.startIndex..., in: fragment),
            withTemplate: "&amp;"
        )

        let matches = namedEntityPattern.matches(
            in: recovered,
            range: NSRange(recovered.startIndex..., in: recovered)
        )
        for match in matches.reversed() {
            guard
                let nameRange = Range(match.range(at: 1), in: recovered),
                let entityRange = Range(match.range, in: recovered)
            else {
                continue
            }
            let name = String(recovered[nameRange])
            if let numericReference = commonHTMLEntities[name] {
                recovered.replaceSubrange(entityRange, with: numericReference)
            } else if !xmlNamedEntities.contains(name) {
                recovered.replaceSubrange(entityRange, with: "&amp;\(name);")
            } else {
                continue
            }
        }

        return recovered
    }

    private static func normalizeEncodingDeclaration(in xml: inout String) {
        let range = NSRange(xml.startIndex..., in: xml)
        guard
            let match = xmlEncodingPattern.firstMatch(in: xml, range: range),
            let encodingRange = Range(match.range(at: 1), in: xml)
        else {
            return
        }

        xml.replaceSubrange(encodingRange, with: "UTF-8")
    }

    private static func decodedXML(from data: Data) -> String? {
        if let xml = String(data: data, encoding: .utf8) {
            return xml
        }

        guard let encoding = declaredEncoding(in: data) else {
            return nil
        }

        return String(data: data, encoding: encoding)
    }

    /// The XML prolog's declared encoding, when one is present and known.
    /// CDATA fallback decoding uses it: XMLParser hands CDATA blocks through
    /// as raw bytes in the document's original encoding.
    static func declaredEncoding(in data: Data) -> String.Encoding? {
        let prefix = String(decoding: data.prefix(1_024), as: Unicode.ASCII.self)
        let range = NSRange(prefix.startIndex..., in: prefix)
        guard
            let match = xmlEncodingPattern.firstMatch(in: prefix, range: range),
            let nameRange = Range(match.range(at: 1), in: prefix)
        else {
            return nil
        }
        return stringEncoding(named: String(prefix[nameRange]))
    }

    private static func stringEncoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
