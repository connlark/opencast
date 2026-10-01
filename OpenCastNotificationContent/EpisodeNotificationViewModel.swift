import Foundation
import ImageIO
import OSLog
import UIKit
import UserNotifications

struct EpisodeNotificationViewModel {
    private static let artworkThumbnailMaxPixelSize = 306
    private static let artworkRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500),
    ]
    private static let artworkLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "NotificationContentArtwork"
    )

    let podcastTitle: String
    let episodeTitle: String
    let durationText: String?
    let summaryText: String?
    var artworkImage: UIImage?
    private let artworkAttachments: [UNNotificationAttachment]

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
        artworkAttachments = content.attachments
        artworkImage = Self.image(from: content.attachments, attempt: 1)
    }

    var hasArtworkAttachments: Bool {
        !artworkAttachments.isEmpty
    }

    func artworkImageAfterRetry() async -> UIImage? {
        if let artworkImage {
            return artworkImage
        }

        guard !artworkAttachments.isEmpty else {
            return nil
        }

        for (index, delay) in Self.artworkRetryDelays.enumerated() {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return nil
            }

            if let image = Self.image(from: artworkAttachments, attempt: index + 2) {
                return image
            }
        }

        return nil
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

        let prose = prose(from: value)
        guard !prose.urlOnly, isUsefulSummary(prose.text, episodeTitle: episodeTitle) else {
            return nil
        }
        return prose.text
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

    // MARK: - Legacy body cleaning
    //
    // Mirrors `notification_text.rs` in the NotificationsWorker. The server
    // ships cleaned prose in `episode_summary`; this fallback only sees the
    // alert body of a payload that had to drop it. Same rules: inline elements
    // add no whitespace, every other element boundary becomes a space,
    // comments and script/style bodies vanish, entities decode to their real
    // characters, and bare URLs shrink to their host.

    private struct Prose {
        let text: String
        /// Every word was a URL before shortening: not a useful summary.
        let urlOnly: Bool
    }

    private static let inlineElements: Set<String> = [
        "a", "abbr", "acronym", "b", "bdi", "bdo", "big", "cite", "code", "data", "del", "dfn",
        "em", "font", "i", "ins", "kbd", "label", "mark", "q", "s", "samp", "small", "span",
        "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr",
    ]
    private static let hiddenElements: Set<String> = [
        "audio", "embed", "iframe", "noscript", "object", "script", "style", "svg", "template",
        "video",
    ]
    private static let attributeDebrisPrefixes = ["href=", "src=", "target=", "rel=", "class=", "style="]
    private static let openingWrappers: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "\u{AB}"]
    private static let closingWrappers: Set<Character> = [
        ")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}", "\u{BB}", ".", ",", ";", ":", "!", "?", "\u{2026}",
    ]
    private static let leadingOrphans: Set<Character> = [",", ";", ":", "-", "_", "|", "/", "\\", ")", "]", "}", "\u{2013}", "\u{2014}"]
    private static let trailingOrphans: Set<Character> = [
        ",", ";", ":", "-", "_", "|", "/", "\\", "(", "[", "{", "\u{2013}", "\u{2014}", "\"", "'", "\u{201C}", "\u{2018}", "\u{AB}",
    ]

    private static func prose(from value: String) -> Prose {
        // Markup that arrived entity-escaped (or double-escaped) only becomes
        // visible after decoding: repeat until the text settles.
        var text = value
        for _ in 0..<4 {
            let next = decodeEntities(in: stripMarkup(text))
            if next == text {
                break
            }
            text = next
        }

        var words: [String] = []
        var urlCount = 0
        var wordCount = 0
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let (open, core, close) = splitWrappingPunctuation(token)
            if isAttributeDebris(core) {
                // A stray attribute from broken markup, usually preceded by
                // its element name.
                if words.last == "a" {
                    words.removeLast()
                    wordCount -= 1
                }
                continue
            }
            if !core.isEmpty {
                wordCount += 1
            }
            var word = token
            if let host = urlHost(core) {
                urlCount += 1
                word = open + host + close
            }
            if let first = word.first, ",.;:!?".contains(first), !words.isEmpty {
                // `parents</a>, and` must not read "parents , and".
                words[words.count - 1] += word
                continue
            }
            words.append(word)
        }

        let joined = words.joined(separator: " ")
        return Prose(text: trimOrphanPunctuation(joined), urlOnly: wordCount > 0 && urlCount == wordCount)
    }

    /// Removes tags, comments and hidden elements, mapping each element
    /// boundary to a space or nothing. Structural characters are ASCII, so the
    /// scan runs on UTF-8 bytes and copies multi-byte text through untouched.
    private static func stripMarkup(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "<") else {
                switch byte {
                case 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
                    output.append(0x20)
                case 0x00..<0x20, 0x7F:
                    break
                default:
                    output.append(byte)
                }
                index += 1
                continue
            }

            let next: UInt8? = index + 1 < bytes.count ? bytes[index + 1] : nil
            if next == UInt8(ascii: "!") {
                let end: Int?
                if bytes[index...].starts(with: Array("<!--".utf8)) {
                    end = firstIndex(of: Array("-->".utf8), in: bytes, from: index + 4).map { $0 + 3 }
                } else {
                    end = firstIndex(of: [UInt8(ascii: ">")], in: bytes, from: index + 2).map { $0 + 1 }
                }
                // An unterminated comment or declaration hides the rest.
                guard let end else {
                    break
                }
                index = end
                output.append(0x20)
            } else if next == UInt8(ascii: "?") {
                guard let end = firstIndex(of: [UInt8(ascii: ">")], in: bytes, from: index + 2) else {
                    break
                }
                index = end + 1
                output.append(0x20)
            } else if let next, next == UInt8(ascii: "/") || isASCIILetter(next) {
                // An unterminated tag at the end of the text renders nothing,
                // like a browser at end of file inside a tag.
                guard let tag = parseTag(in: bytes, from: index + 1) else {
                    break
                }
                index = tag.end
                if !tag.closing, hiddenElements.contains(tag.name) {
                    guard let end = closingTagEnd(of: tag.name, in: bytes, from: index) else {
                        break
                    }
                    index = end
                }
                if !inlineElements.contains(tag.name) {
                    output.append(0x20)
                }
            } else {
                // A lone `<` ("1 < 2", "<3") is text.
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func parseTag(in bytes: [UInt8], from start: Int) -> (name: String, closing: Bool, end: Int)? {
        var index = start
        let closing = index < bytes.count && bytes[index] == UInt8(ascii: "/")
        if closing {
            index += 1
        }
        let nameStart = index
        while index < bytes.count, isASCIILetter(bytes[index]) || isASCIIDigit(bytes[index])
            || bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: ":") {
            index += 1
        }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open {
                    quote = nil
                }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return (name, closing, index + 1)
            }
            index += 1
        }
        return nil
    }

    /// The index after `</name …>` closing a hidden element's content.
    private static func closingTagEnd(of name: String, in bytes: [UInt8], from start: Int) -> Int? {
        let lowered = bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        let target = Array("</\(name)".utf8)
        var from = start
        while let found = firstIndex(of: target, in: lowered, from: from) {
            let afterName = found + target.count
            if afterName >= lowered.count || lowered[afterName] == UInt8(ascii: ">")
                || lowered[afterName] == 0x20 || (0x09...0x0D).contains(lowered[afterName]) {
                return firstIndex(of: [UInt8(ascii: ">")], in: lowered, from: afterName).map { $0 + 1 }
            }
            from = found + 2
        }
        return nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return nil
        }
        var index = start
        while index + needle.count <= haystack.count {
            if haystack[index..<index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    /// Decodes named and numeric character references; unknown names stay
    /// verbatim, as does an `&` that starts no reference.
    private static func decodeEntities(in value: String) -> String {
        guard value.contains("&") else {
            return value
        }

        var output = ""
        var rest = Substring(value)
        while let ampersand = rest.firstIndex(of: "&") {
            output += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            let name = after.prefix(32).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "#") }
            let afterName = after[name.endIndex...]
            if !name.isEmpty, afterName.first == ";" {
                if let decoded = decodeReference(String(name)) {
                    output += decoded
                } else {
                    output += "&\(name);"
                }
                rest = afterName.dropFirst()
            } else {
                output += "&"
                rest = after
            }
        }
        output += rest
        return output
    }

    private static func decodeReference(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits, radix: 10)
            }
            guard let code else {
                return nil
            }
            return numericCharacter(code).map(String.init) ?? ""
        }
        return namedEntity(name)
    }

    /// Browsers map the C1 range to Windows-1252; NUL, controls, surrogates
    /// and out-of-range values render nothing useful in an alert.
    private static func numericCharacter(_ code: UInt32) -> Character? {
        let windows1252: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
            0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
            0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
        ]
        let mapped = (0x80...0x9F).contains(code) ? windows1252[Int(code - 0x80)] : code
        guard let scalar = Unicode.Scalar(mapped) else {
            return nil
        }
        let isControl = scalar.properties.generalCategory == .control
        guard !isControl || Character(scalar).isWhitespace else {
            return nil
        }
        return Character(scalar)
    }

    /// The named references seen in podcast feeds: XML's five, the Latin-1
    /// block (`&nbsp;` … `&yuml;`, in code point order) and common typography.
    private static func namedEntity(_ name: String) -> String? {
        if let position = latin1Entities.firstIndex(of: name),
           let scalar = Unicode.Scalar(0xA0 + UInt32(position)) {
            return String(Character(scalar))
        }
        return typographicEntities[name]
    }

    private static let latin1Entities = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy",
        "ordf", "laquo", "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute",
        "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12",
        "frac34", "iquest", "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig",
        "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
        "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash",
        "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute",
        "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc",
        "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde", "ograve", "oacute",
        "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml",
        "yacute", "thorn", "yuml",
    ]

    private static let typographicEntities: [String: String] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">",
        "quot": "\"", "QUOT": "\"", "apos": "'",
        "ensp": " ", "emsp": " ", "thinsp": " ", "numsp": " ", "puncsp": " ",
        "zwnj": "", "zwj": "", "lrm": "", "rlm": "",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "bull": "\u{2022}", "bullet": "\u{2022}",
        "hellip": "\u{2026}", "mldr": "\u{2026}", "permil": "\u{2030}", "prime": "\u{2032}",
        "Prime": "\u{2033}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "oline": "\u{203E}",
        "frasl": "\u{2044}", "euro": "\u{20AC}", "trade": "\u{2122}", "TRADE": "\u{2122}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
        "harr": "\u{2194}", "crarr": "\u{21B5}", "minus": "\u{2212}", "lowast": "\u{2217}",
        "radic": "\u{221A}", "infin": "\u{221E}", "ne": "\u{2260}", "le": "\u{2264}",
        "ge": "\u{2265}", "loz": "\u{25CA}", "spades": "\u{2660}", "clubs": "\u{2663}",
        "hearts": "\u{2665}", "diams": "\u{2666}", "check": "\u{2713}", "checkmark": "\u{2713}",
        "starf": "\u{2605}", "bigstar": "\u{2605}", "star": "\u{2606}",
        "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}", "scaron": "\u{0161}",
        "Yuml": "\u{0178}", "fnof": "\u{0192}", "circ": "\u{02C6}", "tilde": "\u{02DC}",
    ]

    /// Splits `(word)."` into its opening wrapper, core and closing punctuation.
    private static func splitWrappingPunctuation(_ token: String) -> (open: String, core: String, close: String) {
        let open = token.prefix { openingWrappers.contains($0) }
        let remainder = token[open.endIndex...]
        let core = remainder.reversed().drop { closingWrappers.contains($0) }.reversed()
        let coreEnd = remainder.index(remainder.startIndex, offsetBy: core.count)
        return (String(open), String(remainder[..<coreEnd]), String(remainder[coreEnd...]))
    }

    private static func isAttributeDebris(_ core: String) -> Bool {
        let lowered = core.lowercased()
        return attributeDebrisPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// The host of a bare `http(s)://` or `www.` URL, without `www.`; `nil`
    /// when the word is not a URL with a dotted host ("https://" alone,
    /// "foo://").
    private static func urlHost(_ core: String) -> String? {
        let lowered = core.lowercased()
        let hostStart: Int
        if lowered.hasPrefix("https://") {
            hostStart = 8
        } else if lowered.hasPrefix("http://") {
            hostStart = 7
        } else if lowered.hasPrefix("www.") {
            hostStart = 0
        } else {
            return nil
        }
        let authority = core.dropFirst(hostStart)
        var host = String(authority.prefix { !"/?#:".contains($0) })
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let valid = host.contains(".")
            && !host.hasPrefix(".")
            && !host.hasSuffix(".")
            && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return valid ? host : nil
    }

    private static func isURLOnly(_ value: String) -> Bool {
        let cores = value
            .split(whereSeparator: \.isWhitespace)
            .map { splitWrappingPunctuation(String($0)).core }
            .filter { !$0.isEmpty }
        return !cores.isEmpty && cores.allSatisfy { urlHost($0) != nil }
    }

    private static func trimOrphanPunctuation(_ value: String) -> String {
        let leading = value.drop { $0.isWhitespace || leadingOrphans.contains($0) }
        let trailing = leading.reversed().drop { $0.isWhitespace || trailingOrphans.contains($0) }
        return String(trailing.reversed())
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        collapseWhitespace(lhs).lowercased() == collapseWhitespace(rhs).lowercased()
    }

    private static func preferredArtworkAttachments(
        from attachments: [UNNotificationAttachment]
    ) -> [UNNotificationAttachment] {
        guard let episodeArtworkIndex = attachments.firstIndex(where: {
            $0.identifier == NotificationArtworkAttachmentIdentifier.episode
        }) else {
            return attachments
        }

        var orderedAttachments = attachments
        let episodeArtwork = orderedAttachments.remove(at: episodeArtworkIndex)
        orderedAttachments.insert(episodeArtwork, at: 0)
        return orderedAttachments
    }

    private static func image(
        from attachments: [UNNotificationAttachment],
        attempt: Int
    ) -> UIImage? {
        artworkLogger.notice(
            "Decode attempt \(attempt, privacy: .public) received \(attachments.count, privacy: .public) attachment(s)."
        )

        for (index, attachment) in preferredArtworkAttachments(from: attachments).enumerated() {
            if let image = image(from: attachment, position: index + 1, attempt: attempt) {
                return image
            }
        }

        if !attachments.isEmpty {
            artworkLogger.error(
                "Decode attempt \(attempt, privacy: .public) could not decode any attachment."
            )
        }
        return nil
    }

    private static func image(
        from attachment: UNNotificationAttachment,
        position: Int,
        attempt: Int
    ) -> UIImage? {
        let url = attachment.url
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
        } catch {
            artworkLogger.error(
                """
                Decode attempt \(attempt, privacy: .public) could not read attachment \
                \(position, privacy: .public); security scope granted: \(isSecurityScoped, privacy: .public).
                """
            )
            return nil
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            artworkLogger.error(
                """
                Decode attempt \(attempt, privacy: .public) could not create an image source for attachment \
                \(position, privacy: .public) with \(data.count, privacy: .public) byte(s).
                """
            )
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkThumbnailMaxPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            artworkLogger.error(
                """
                Decode attempt \(attempt, privacy: .public) could not create a thumbnail for attachment \
                \(position, privacy: .public) with \(data.count, privacy: .public) byte(s).
                """
            )
            return nil
        }

        artworkLogger.notice(
            """
            Decode attempt \(attempt, privacy: .public) loaded attachment \
            \(position, privacy: .public) with \(data.count, privacy: .public) byte(s); \
            security scope granted: \(isSecurityScoped, privacy: .public).
            """
        )
        return UIImage(cgImage: image)
    }
}
