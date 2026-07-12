import Foundation

/// Renders podcast show-notes HTML as an `AttributedString` using only
/// presentation intents and links, so Dynamic Type and both color schemes
/// style the result. Handles the same tag set as `HTMLPlainText`; anything
/// unknown is stripped and malformed input degrades to the plain-text path.
enum HTMLAttributedText {
    nonisolated static func attributedString(from html: String) -> AttributedString {
        let rendered = render(preprocess(html))
        guard String(rendered.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return detectingPhoneNumbers(in: rendered)
        }

        return AttributedString(HTMLPlainText.structuredText(from: html))
    }

    /// The rendered text split at paragraph breaks. Views render each block
    /// as its own `Text` inside a lazy stack — a single `Text` holding very
    /// long show notes stops painting past the renderer's tile limits.
    nonisolated static func attributedBlocks(from html: String) -> [AttributedString] {
        let rendered = attributedString(from: html)
        let plain = String(rendered.characters)
        guard !plain.isEmpty else {
            return []
        }

        var blocks: [AttributedString] = []
        var cursor = plain.startIndex
        while cursor < plain.endIndex {
            let separator = plain.range(of: "\n\n", range: cursor..<plain.endIndex)
            let blockEnd = separator?.lowerBound ?? plain.endIndex
            if cursor < blockEnd,
               let blockRange = Range(NSRange(cursor..<blockEnd, in: plain), in: rendered) {
                blocks.append(AttributedString(rendered[blockRange]))
            }
            cursor = separator?.upperBound ?? plain.endIndex
        }
        return blocks
    }

    nonisolated private static func preprocess(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|svg|iframe|object|embed)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<(figure|audio|video)\b[^>]*>.*?</\1>"#,
            with: "<p>",
            options: .regularExpression
        )
        return text
    }

    nonisolated private static func render(_ html: String) -> AttributedString {
        guard let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#) else {
            return AttributedString(HTMLPlainText.structuredText(from: html))
        }

        var renderer = Renderer()
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var cursor = html.startIndex
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let tagRange = Range(match.range, in: html) else {
                continue
            }

            renderer.appendText(String(html[cursor..<tagRange.lowerBound]))
            renderer.handleTag(html[tagRange])
            cursor = tagRange.upperBound
        }
        renderer.appendText(String(html[cursor...]))
        return renderer.output
    }

    nonisolated private static func linkURL(fromTag tag: Substring) -> URL? {
        let tagText = String(tag)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\bhref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>'"]+))"#
        ) else {
            return nil
        }

        let range = NSRange(tagText.startIndex..<tagText.endIndex, in: tagText)
        guard let match = regex.firstMatch(in: tagText, range: range) else {
            return nil
        }

        var rawValue: String?
        for groupIndex in [2, 3, 4] {
            if let groupRange = Range(match.range(at: groupIndex), in: tagText) {
                rawValue = String(tagText[groupRange])
                break
            }
        }

        guard let rawValue,
              let url = URL(string: HTMLPlainText.decodeEntities(in: rawValue).trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else {
            return nil
        }
        return url
    }

    /// Above this size the input is a pathological fixture, not show notes;
    /// scanning it would stall content resolution for seconds.
    nonisolated private static let phoneDetectionCharacterLimit = 200_000

    nonisolated private static func detectingPhoneNumbers(in attributed: AttributedString) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else {
            return attributed
        }

        var result = attributed
        let plain = String(attributed.characters)
        guard plain.count <= Self.phoneDetectionCharacterLimit else {
            return attributed
        }
        let fullRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, range: fullRange) {
            guard let phoneNumber = match.phoneNumber,
                  let range = Range(match.range, in: result),
                  result[range].runs[\.link].allSatisfy({ $0.0 == nil })
            else {
                continue
            }

            let dialable = phoneNumber.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
            guard !dialable.isEmpty, let url = URL(string: "tel:\(dialable)") else {
                continue
            }
            result[range].link = url
        }
        return result
    }

    private enum Separator: Int, Comparable {
        case none
        case space
        case line
        case paragraph

        nonisolated static func < (lhs: Separator, rhs: Separator) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Renderer {
        var output = AttributedString()
        private var pendingSeparator = Separator.none
        private var pendingBulletPrefix = false
        private var strongDepth = 0
        private var emphasisDepth = 0
        private var headingDepth = 0
        private var linkTargets: [URL?] = []

        nonisolated mutating func appendText(_ raw: String) {
            guard !raw.isEmpty else {
                return
            }

            let decoded = HTMLPlainText.decodeEntities(in: raw)
            let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !collapsed.isEmpty else {
                return
            }
            guard collapsed != " " else {
                requestSeparator(.space)
                return
            }

            var text = Substring(collapsed)
            if text.hasPrefix(" ") {
                requestSeparator(.space)
                text = text.dropFirst()
            }
            let endsWithSpace = text.hasSuffix(" ")
            if endsWithSpace {
                text = text.dropLast()
            }

            flushSeparator()
            if pendingBulletPrefix {
                pendingBulletPrefix = false
                output.append(styledRun("• ", includingLink: false))
            }
            output.append(styledRun(String(text)))
            if endsWithSpace {
                requestSeparator(.space)
            }
        }

        nonisolated mutating func handleTag(_ tag: Substring) {
            let inner = tag.dropFirst().dropLast()
            let isClosing = inner.hasPrefix("/")
            let nameSource = isClosing ? inner.dropFirst() : inner
            let name = String(nameSource.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            guard !name.isEmpty else {
                return
            }

            switch name {
            case "br":
                requestSeparator(.line)
            case "hr", "p", "div", "section", "article", "header", "footer", "blockquote", "table", "tr", "ul", "ol":
                requestSeparator(.paragraph)
                if isClosing, name == "ul" || name == "ol" {
                    pendingBulletPrefix = false
                }
            case "li":
                requestSeparator(.line)
                pendingBulletPrefix = !isClosing
            case "h1", "h2", "h3", "h4", "h5", "h6":
                requestSeparator(.paragraph)
                headingDepth = max(0, headingDepth + (isClosing ? -1 : 1))
            case "b", "strong":
                strongDepth = max(0, strongDepth + (isClosing ? -1 : 1))
            case "i", "em":
                emphasisDepth = max(0, emphasisDepth + (isClosing ? -1 : 1))
            case "a":
                if isClosing {
                    if !linkTargets.isEmpty {
                        linkTargets.removeLast()
                    }
                } else {
                    linkTargets.append(HTMLAttributedText.linkURL(fromTag: inner))
                }
            default:
                break
            }
        }

        nonisolated private mutating func requestSeparator(_ separator: Separator) {
            guard !output.characters.isEmpty else {
                return
            }

            pendingSeparator = max(pendingSeparator, separator)
        }

        nonisolated private mutating func flushSeparator() {
            switch pendingSeparator {
            case .none:
                break
            case .space:
                output.append(AttributedString(" "))
            case .line:
                output.append(AttributedString("\n"))
            case .paragraph:
                output.append(AttributedString("\n\n"))
            }
            pendingSeparator = .none
        }

        nonisolated private func styledRun(_ text: String, includingLink: Bool = true) -> AttributedString {
            var run = AttributedString(text)
            var intent = InlinePresentationIntent()
            if strongDepth > 0 || headingDepth > 0 {
                intent.insert(.stronglyEmphasized)
            }
            if emphasisDepth > 0 {
                intent.insert(.emphasized)
            }
            if !intent.isEmpty {
                run.inlinePresentationIntent = intent
            }
            if includingLink, let link = linkTargets.last ?? nil {
                run.link = link
            }
            return run
        }
    }
}
