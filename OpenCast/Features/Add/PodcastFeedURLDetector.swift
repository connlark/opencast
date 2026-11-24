import Foundation

enum PodcastFeedURLDetector {
    nonisolated static func isAddressLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        return trimmed.contains("://")
            || lowercased.hasPrefix("http:")
            || lowercased.hasPrefix("https:")
            || trimmed.split(whereSeparator: \.isWhitespace).contains { word in
                let address = SchemelessAddress(word)
                return address.hasPassword || (address.hasHost && (address.hasPath || address.hasUser))
            }
    }

    nonisolated static func openableFeedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = webURL(trimmed) {
            return url
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
            return nil
        }
        let address = SchemelessAddress(Substring(trimmed))
        return address.hasHost && address.hasPath ? webURL("https://\(address.text)") : nil
    }

    private nonisolated static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }

    private nonisolated struct SchemelessAddress {
        let text: Substring
        let hasPath: Bool
        let hasUser: Bool
        let hasPassword: Bool
        let hasHost: Bool

        init(_ word: Substring) {
            text = word.hasPrefix("//") ? word.dropFirst(2) : word
            let authority = text.prefix { $0 != "/" }
            hasPath = authority.endIndex != text.endIndex

            var host = authority
            var userInfo = Substring()
            if let at = authority.lastIndex(of: "@") {
                userInfo = authority[..<at]
                host = authority[authority.index(after: at)...]
            }
            hasUser = !userInfo.isEmpty
            hasPassword = userInfo.dropFirst().contains(":")

            let isBracketed = host.hasPrefix("[") && host.contains("]")
            var hasPort = false
            if !isBracketed, let colon = host.lastIndex(of: ":") {
                let port = host[host.index(after: colon)...]
                if !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    hasPort = true
                    host = host[..<colon]
                }
            }
            hasHost = !host.isEmpty && (
                isBracketed
                    || Self.isIPv4(host)
                    || (hasPort && host.contains(where: \.isLetter))
                    || Self.isDottedName(host)
                    || hasPassword
            )
        }

        private static func isDottedName(_ host: Substring) -> Bool {
            guard host.contains("."), let lastLabel = host.split(separator: ".", omittingEmptySubsequences: false).last else {
                return false
            }
            return lastLabel.count >= 2 && lastLabel.allSatisfy(\.isLetter)
        }

        private static func isIPv4(_ host: Substring) -> Bool {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { part in
                part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part).map { $0 <= 255 } == true
            }
        }
    }
}
