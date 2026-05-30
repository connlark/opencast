import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct OPMLParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> [OPMLFeedReference] {
        try parseResult(data: data).feedReferences
    }

    public func parseResult(data: Data) throws -> OPMLParseResult {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            throw OPMLError.malformedDocument
        }

        guard !delegate.feedReferences.isEmpty else {
            throw OPMLError.emptySubscriptionList
        }

        return OPMLParseResult(
            feedReferences: delegate.feedReferences,
            usableFeedReferenceCount: delegate.usableFeedReferenceCount,
            duplicateFeedReferenceCount: delegate.duplicateFeedReferenceCount
        )
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var feedReferences: [OPMLFeedReference] = []
    private(set) var usableFeedReferenceCount = 0
    private(set) var duplicateFeedReferenceCount = 0
    private var seenCanonicalFeedURLs: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.caseInsensitiveCompare("outline") == .orderedSame else {
            return
        }

        let attributes = OPMLAttributes(attributeDict)
        guard let feedURL = Self.validWebURL(from: attributes.value(for: "xmlUrl")) else {
            return
        }

        let htmlURL = Self.validWebURL(from: attributes.value(for: "htmlUrl"))
        let reference = OPMLFeedReference(
            title: Self.title(from: attributes, feedURL: feedURL),
            feedURL: feedURL,
            htmlURL: htmlURL
        )

        usableFeedReferenceCount += 1

        guard seenCanonicalFeedURLs.insert(reference.canonicalFeedURL).inserted else {
            duplicateFeedReferenceCount += 1
            return
        }

        feedReferences.append(reference)
    }

    private static func title(from attributes: OPMLAttributes, feedURL: URL) -> String? {
        if let text = attributes.value(for: "text") {
            return text
        }

        if let title = attributes.value(for: "title") {
            return title
        }

        return feedURL.host
    }

    private static func validWebURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false
        else {
            return nil
        }

        return url
    }
}

private struct OPMLAttributes {
    private var values: [String: String] = [:]

    init(_ rawValues: [String: String]) {
        values = Dictionary(
            rawValues.map { key, value in (key.lowercased(), value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func value(for key: String) -> String? {
        guard let value = values[key.lowercased()]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }
}
