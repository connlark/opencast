import Foundation

public struct RSSFeedParser: Sendable {
    public init() {}

    public func parse(data: Data, feedURL: URL) throws -> FeedSnapshot {
        let delegate = FeedXMLParserDelegate(feedURL: feedURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? OpenCastCoreError.emptyFeed
        }

        return try delegate.snapshot()
    }
}

private final class FeedXMLParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private var channel = ChannelAccumulator()
    private var currentItem: ItemAccumulator?
    private var items: [ItemAccumulator] = []
    private var elementStack: [String] = []
    private var textBuffer = ""

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func snapshot() throws -> FeedSnapshot {
        let podcastID = URLCanonicalizer.podcastID(for: feedURL)
        let podcastTitle = channel.title.nilIfBlank ?? feedURL.host ?? feedURL.absoluteString
        let podcast = Podcast(
            id: podcastID,
            feedURL: feedURL,
            title: podcastTitle,
            author: channel.author.nilIfBlank,
            summary: channel.summary.nilIfBlank,
            websiteURL: channel.websiteURL,
            artworkURL: channel.artworkURL
        )

        let episodes = items.compactMap { item -> Episode? in
            let title = item.title.nilIfBlank ?? "Untitled Episode"
            let id = EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: item.guid.nilIfBlank,
                audioURL: item.audioURL,
                title: title,
                publishedAt: item.publishedAt
            )

            return Episode(
                id: id,
                podcastID: podcastID,
                podcastTitle: podcastTitle,
                title: title,
                summary: item.summary.nilIfBlank,
                showNotesHTML: item.showNotesHTML.nilIfBlank ?? item.summary.nilIfBlank,
                publishedAt: item.publishedAt,
                duration: item.duration,
                audioURL: item.audioURL,
                artworkURL: item.artworkURL ?? channel.artworkURL,
                guid: item.guid.nilIfBlank
            )
        }

        guard !episodes.isEmpty else {
            throw OpenCastCoreError.emptyFeed
        }

        return FeedSnapshot(podcast: podcast, episodes: episodes)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName, qName: qName)
        elementStack.append(name)
        textBuffer = ""

        switch name {
        case "item":
            currentItem = ItemAccumulator()
        case "enclosure":
            currentItem?.audioURL = attributeDict.caseInsensitiveValue(for: "url").flatMap(URL.init(string:))
        case "itunes:image":
            if let url = attributeDict.caseInsensitiveValue(for: "href").flatMap(URL.init(string:)) {
                if currentItem == nil {
                    channel.artworkURL = url
                } else {
                    currentItem?.artworkURL = url
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        textBuffer += value
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName, qName: qName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentItem == nil {
            applyChannelValue(name: name, value: value)
        } else {
            applyItemValue(name: name, value: value)
        }

        if name == "item", let currentItem {
            items.append(currentItem)
            self.currentItem = nil
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        textBuffer = ""
    }

    private func applyChannelValue(name: String, value: String) {
        switch name {
        case "title":
            channel.title = value
        case "description", "itunes:summary":
            if channel.summary.nilIfBlank == nil {
                channel.summary = value
            }
        case "link":
            channel.websiteURL = URL(string: value)
        case "itunes:author", "author":
            channel.author = value
        case "url" where elementStack.contains("image"):
            channel.artworkURL = URL(string: value)
        default:
            break
        }
    }

    private func applyItemValue(name: String, value: String) {
        switch name {
        case "title":
            currentItem?.title = value
        case "guid":
            currentItem?.guid = value
        case "description", "itunes:summary":
            if currentItem?.summary.nilIfBlank == nil {
                currentItem?.summary = value
            }
        case "content:encoded":
            currentItem?.showNotesHTML = value
        case "pubdate":
            currentItem?.publishedAt = RSSDateParser.parse(value)
        case "itunes:duration":
            currentItem?.duration = DurationParser.parse(value)
        default:
            break
        }
    }

    private func normalizedName(_ elementName: String, qName: String?) -> String {
        (qName ?? elementName).lowercased()
    }
}

private struct ChannelAccumulator {
    var title: String?
    var author: String?
    var summary: String?
    var websiteURL: URL?
    var artworkURL: URL?
}

private struct ItemAccumulator {
    var title: String?
    var guid: String?
    var summary: String?
    var showNotesHTML: String?
    var publishedAt: Date?
    var duration: TimeInterval?
    var audioURL: URL?
    var artworkURL: URL?
}

private extension Dictionary where Key == String, Value == String {
    func caseInsensitiveValue(for key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
