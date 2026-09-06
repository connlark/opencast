import Foundation

public struct RSSFeedParser: Sendable {
    private static let feedRootElements: Set<String> = ["rss", "rdf:rdf", "rdf"]

    public init() {}

    public func parse(data: Data, feedURL: URL) throws -> FeedSnapshot {
        let original = parseXML(data: data, feedURL: feedURL)
        if original.error == nil {
            return try snapshot(from: original.delegate)
        }

        // A budget abort is not an entity problem: recovery cannot reduce the
        // work, and regex-reprocessing an oversized document would evade the
        // budgets it just enforced.
        var salvageCandidate = original.delegate
        if !original.delegate.didExceedWorkBudget,
           let recoveredData = RSSFeedRecovery.recoveredData(from: data) {
            let recovered = parseXML(data: recoveredData, feedURL: feedURL)
            if recovered.error == nil {
                return try snapshot(from: recovered.delegate)
            }
            if recovered.delegate.itemCount > salvageCandidate.itemCount {
                salvageCandidate = recovered.delegate
            }
        }

        if salvageCandidate.itemCount > 0,
           let rootElement = salvageCandidate.rootElementName,
           Self.feedRootElements.contains(rootElement) {
            return salvageCandidate.snapshot(isSalvaged: true)
        }

        throw classifiedParseError(delegate: original.delegate, underlying: original.error)
    }

    private func snapshot(from delegate: FeedXMLParserDelegate) throws -> FeedSnapshot {
        if let rootElement = delegate.rootElementName,
           !Self.feedRootElements.contains(rootElement) {
            throw OpenCastCoreError.notAFeed(rootElement: rootElement)
        }
        return delegate.snapshot()
    }

    private func classifiedParseError(
        delegate: FeedXMLParserDelegate,
        underlying: (any Error)?
    ) -> any Error {
        if let rootElement = delegate.rootElementName,
           !Self.feedRootElements.contains(rootElement) {
            return OpenCastCoreError.notAFeed(rootElement: rootElement)
        }
        if delegate.didExceedWorkBudget {
            return OpenCastCoreError.malformedFeed(reason: "Parser work budget exceeded.")
        }
        return OpenCastCoreError.malformedFeed(reason: underlying?.localizedDescription)
    }

    private func parseXML(
        data: Data,
        feedURL: URL
    ) -> (delegate: FeedXMLParserDelegate, error: (any Error)?) {
        let delegate = FeedXMLParserDelegate(
            feedURL: feedURL,
            fallbackCDATAEncoding: RSSFeedRecovery.declaredEncoding(in: data)
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            return (delegate, parser.parserError ?? OpenCastCoreError.malformedFeed(reason: nil))
        }

        return (delegate, nil)
    }
}

/// DoS rails, not product limits: sized comfortably above anything a
/// legitimate feed produces, including the text amplification the
/// didEndElement bubble-up adds while it remains uncontained.
private enum ParserWorkBudget {
    static let maxElementDepth = FeedResourcePolicy.maximumDepth
    static let maxItems = FeedResourcePolicy.maximumItems
    static let maxTextNodeBytes = FeedResourcePolicy.maximumFieldBytes
    static let maxAggregateTextBytes = FeedResourcePolicy.maximumProcessingBytes
}

final class FeedXMLParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private var channel = ChannelAccumulator()
    private var currentItem: ItemAccumulator?
    private var items: [ItemAccumulator] = []
    private var elementStack: [String] = []
    private var textBuffers: [String] = []
    private var textBufferBytes: [Int] = []
    private var aggregateTextBytes = 0
    private var itemTextBytes = 0
    private var rawItemCount = 0
    private var completedItemCount = 0
    private let itemSink: ((ItemAccumulator) throws -> Void)?
    private(set) var sinkError: (any Error)?
    private(set) var incompleteReason: FeedIncompleteReason?
    private(set) var wasCancelled = false
    private let fallbackCDATAEncoding: String.Encoding?
    private(set) var rootElementName: String?
    private(set) var didExceedWorkBudget = false
    /// Per-prefix stacks of "is this the Podcast Index namespace?", seeded
    /// with the canonical prefix. `podcast:chapters` presence gates paid
    /// chapter generation, so a feed binding the namespace to a non-canonical
    /// prefix must not defeat it. Namespace processing is off (prefixes
    /// arrive verbatim), so xmlns declarations are tracked by element scope:
    /// each element's declarations shadow outer ones and are unwound when it
    /// closes, so a prefix rebound to a foreign namespace stops matching for
    /// exactly that subtree — and vice versa.
    private var podcastPrefixBindings: [String: [Bool]] = ["podcast": [true]]
    /// Aligned with `elementStack`: the prefixes each open element declared.
    private var declaredNamespacePrefixStack: [[String]] = []

    private static let podcastNamespaceURIs: Set<String> = [
        "https://podcastindex.org/namespace/1.0",
        "https://github.com/podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
    ]

    /// - Parameter fallbackCDATAEncoding: the document's prolog-declared
    ///   encoding; CDATA blocks arrive as raw bytes in that encoding.
    init(feedURL: URL, fallbackCDATAEncoding: String.Encoding?, itemSink: ((ItemAccumulator) throws -> Void)? = nil) {
        self.itemSink = itemSink
        self.feedURL = feedURL
        self.fallbackCDATAEncoding = fallbackCDATAEncoding
    }

    var itemCount: Int {
        completedItemCount
    }

    var newFeedURL: URL? { channel.newFeedURL }

    var podcastMetadata: Podcast {
        let podcastID = URLCanonicalizer.podcastID(for: feedURL)
        let podcastTitle = channel.title.nilIfBlank ?? feedURL.host ?? feedURL.absoluteString
        return Podcast(
            id: podcastID,
            feedURL: feedURL,
            title: podcastTitle,
            author: channel.author.nilIfBlank,
            summary: channel.summary.nilIfBlank,
            websiteURL: channel.websiteURL,
            artworkURL: channel.artworkURL,
            languageCode: RSSLanguageNormalizer.normalized(channel.language),
            podcastGUID: channel.podcastGUID.nilIfBlank
        )

    }

    func snapshot(isSalvaged: Bool = false) -> FeedSnapshot {
        let podcast = podcastMetadata
        let podcastID = podcast.id
        let podcastTitle = podcast.title

        var episodes: [Episode] = []
        episodes.reserveCapacity(items.count)
        var seenIDs = Set<EpisodeID>()
        var seenMaterialKeys = Set<String>()

        // Material duplicates are filtered first so they never influence
        // collision-winner selection.
        var pendingItems: [(item: ItemAccumulator, title: String, naturalID: EpisodeID)] = []
        pendingItems.reserveCapacity(items.count)
        var indexesByNaturalID: [EpisodeID: [Int]] = [:]
        for item in items {
            let title = item.title.nilIfBlank ?? "Untitled Episode"
            let materialKey = [
                item.guid.nilIfBlank ?? "",
                item.audioURL?.absoluteString ?? "",
                title,
                item.publishedAt.map { String($0.timeIntervalSince1970) } ?? ""
            ].joined(separator: "|")
            guard seenMaterialKeys.insert(materialKey).inserted else {
                continue
            }
            let naturalID = EpisodeIdentity.makeID(
                canonicalFeedURL: podcastID.rawValue,
                guid: item.guid.nilIfBlank,
                audioURL: item.audioURL,
                title: title,
                publishedAt: item.publishedAt
            )
            indexesByNaturalID[naturalID, default: []].append(pendingItems.count)
            pendingItems.append((item: item, title: title, naturalID: naturalID))
        }

        // A collision group's natural-tier ID goes to a content-determined
        // winner, not to whichever collider the publisher listed first: a
        // newest-first feed prepending a new item with a reused GUID must not
        // re-key the existing episode and orphan its synced progress.
        var naturalTierWinnerIndexes: [EpisodeID: Int] = [:]
        for (naturalID, indexes) in indexesByNaturalID where indexes.count > 1 {
            let winnerIndex = indexes.min { lhs, rhs in
                Self.naturalTierPrecedes(pendingItems[lhs], pendingItems[rhs])
            }
            if let winnerIndex {
                naturalTierWinnerIndexes[naturalID] = winnerIndex
            }
        }

        for (index, pending) in pendingItems.enumerated() {
            let item = pending.item
            let id: EpisodeID?
            if let winnerIndex = naturalTierWinnerIndexes[pending.naturalID],
               winnerIndex != index {
                id = fallbackEpisodeID(
                    for: item,
                    title: pending.title,
                    canonicalFeedURL: podcastID.rawValue,
                    seenIDs: seenIDs
                )
            } else if !seenIDs.contains(pending.naturalID) {
                id = pending.naturalID
            } else {
                id = fallbackEpisodeID(
                    for: item,
                    title: pending.title,
                    canonicalFeedURL: podcastID.rawValue,
                    seenIDs: seenIDs
                )
            }
            guard let id else {
                continue
            }
            seenIDs.insert(id)

            episodes.append(
                Episode(
                    id: id,
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: pending.title,
                    summary: item.summary.nilIfBlank,
                    showNotesHTML: item.showNotesHTML.nilIfBlank ?? item.summary.nilIfBlank,
                    publishedAt: item.publishedAt,
                    duration: item.duration,
                    audioURL: item.audioURL,
                    artworkURL: item.artworkURL ?? channel.artworkURL,
                    guid: item.guid.nilIfBlank,
                    chaptersURL: item.chaptersURL
                )
            )
        }

        return FeedSnapshot(
            podcast: podcast,
            episodes: episodes,
            isSalvaged: isSalvaged,
            newFeedURL: channel.newFeedURL
        )
    }

    /// Natural-tier collision-winner ordering: oldest publishedAt first
    /// (stable under newest-first prepends — the existing episode keeps its
    /// ID), then lexicographically smallest audio URL, then document order
    /// (min-by keeps the earlier index on full ties).
    private static func naturalTierPrecedes(
        _ lhs: (item: ItemAccumulator, title: String, naturalID: EpisodeID),
        _ rhs: (item: ItemAccumulator, title: String, naturalID: EpisodeID)
    ) -> Bool {
        switch (lhs.item.publishedAt, rhs.item.publishedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        switch (lhs.item.audioURL?.absoluteString, rhs.item.audioURL?.absoluteString) {
        case let (lhsURL?, rhsURL?):
            return lhsURL < rhsURL
        case (.some, .none):
            return true
        default:
            return false
        }
    }

    /// Publishers occasionally reuse one GUID (or enclosure) across distinct
    /// episodes; without a fallback every collider collapses into one row.
    /// The content-determined winner keeps the natural-tier ID so existing
    /// libraries don't re-key; the other colliders fall back a tier at a
    /// time. Items whose identity material is identical at every tier are
    /// true duplicates and collapse to nil.
    private func fallbackEpisodeID(
        for item: ItemAccumulator,
        title: String,
        canonicalFeedURL: String,
        seenIDs: Set<EpisodeID>
    ) -> EpisodeID? {
        let guid = item.guid.nilIfBlank
        var fallbacks: [EpisodeID] = []
        if guid != nil, item.audioURL != nil {
            fallbacks.append(
                EpisodeIdentity.makeID(
                    canonicalFeedURL: canonicalFeedURL,
                    guid: nil,
                    audioURL: item.audioURL,
                    title: title,
                    publishedAt: item.publishedAt
                )
            )
        }
        if guid != nil || item.audioURL != nil {
            fallbacks.append(
                EpisodeIdentity.makeID(
                    canonicalFeedURL: canonicalFeedURL,
                    guid: nil,
                    audioURL: nil,
                    title: title,
                    publishedAt: item.publishedAt
                )
            )
        }
        return fallbacks.first { !seenIDs.contains($0) }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName, qName: qName)
        if rootElementName == nil {
            rootElementName = name
        }
        elementStack.append(name)
        textBuffers.append("")
        textBufferBytes.append(0)
        if elementStack.count > ParserWorkBudget.maxElementDepth {
            exceed(.depthLimit)
        }
        pushNamespaceBindings(attributes: attributeDict)
        switch name {
        case "item":
            rawItemCount += 1
            if rawItemCount > ParserWorkBudget.maxItems { exceed(.itemLimit) }
            if currentItem != nil { incompleteReason = .malformedXML("Nested RSS item."); parser.abortParsing(); return }
            itemTextBytes = 0
            currentItem = ItemAccumulator()
        case "enclosure":
            captureEnclosure(attributes: attributeDict)
        case _ where isPodcastChaptersElement(name):
            // Attribute-bearing element (url/type); presence gates generated
            // chapters — creator metadata wins.
            if currentItem != nil,
               let url = attributeDict.caseInsensitiveValue(for: "url").flatMap(URL.init(string:)) {
                currentItem?.chaptersURL = url
            }
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

        for value in attributeDict.values {
            if value.utf8.count > ParserWorkBudget.maxTextNodeBytes { exceed(.fieldLimit) }
            accountText(value.utf8.count, itemText: currentItem != nil)
        }

        abortIfOverBudget(parser)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
        abortIfOverBudget(parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        appendText(decodedCDATA(CDATABlock))
        abortIfOverBudget(parser)
    }

    /// CDATA arrives as raw bytes in the document's original encoding; a
    /// non-UTF-8 block on a feed that parses fine otherwise used to be
    /// silently dropped. Prolog-declared encoding first, then lossy UTF-8.
    private func decodedCDATA(_ block: Data) -> String {
        if let value = String(data: block, encoding: .utf8) {
            return value
        }
        if let fallbackCDATAEncoding, let value = String(data: block, encoding: fallbackCDATAEncoding) {
            return value
        }
        return String(decoding: block, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName, qName: qName)
        let rawValue = textBuffers.popLast() ?? ""
        let rawValueBytes = textBufferBytes.popLast() ?? 0
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentItem == nil {
            applyChannelValue(name: name, value: value)
        } else {
            applyItemValue(name: name, value: value)
        }

        if name == "item", let currentItem {
            if !didExceedWorkBudget {
                do {
                    if let itemSink { try itemSink(currentItem) } else { items.append(currentItem) }
                    completedItemCount += 1
                } catch { sinkError = error }
                self.currentItem = nil
            }
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
            popNamespaceBindings()
        }
        // Bubble closed-element text up into text-bearing parents only: it
        // exists so unescaped inline elements (<b>, <em>) keep accumulating
        // into the field that contains them, and containers accumulating the
        // whole document's character data is pure amplification.
        if !Self.containerElements.contains(name),
           let parentName = elementStack.last,
           !Self.containerElements.contains(parentName) {
            appendText(rawValue, utf8Bytes: rawValueBytes, itemText: false)
        }
        abortIfOverBudget(parser)
    }

    private static let containerElements: Set<String> = [
        "item", "channel", "rss", "rdf:rdf", "rdf", "image", "textinput"
    ]

    private func abortIfOverBudget(_ parser: XMLParser) {
        if Task.isCancelled { wasCancelled = true }
        if didExceedWorkBudget || sinkError != nil || wasCancelled {
            parser.abortParsing()
        }
    }

    private func appendText(_ value: String) {
        appendText(value, utf8Bytes: value.utf8.count)
    }

    private func appendText(_ value: String, utf8Bytes: Int, itemText: Bool = true) {
        guard let index = textBuffers.indices.last else { return }
        accountText(utf8Bytes, itemText: itemText && currentItem != nil)
        if textBufferBytes[index] + utf8Bytes > ParserWorkBudget.maxTextNodeBytes { exceed(.fieldLimit) }
        guard !didExceedWorkBudget else { return }
        textBuffers[index] += value
        textBufferBytes[index] += utf8Bytes
    }

    private func accountText(_ bytes: Int, itemText: Bool) {
        aggregateTextBytes += bytes
        if itemText { itemTextBytes += bytes }
        if aggregateTextBytes > ParserWorkBudget.maxAggregateTextBytes { exceed(.processingLimit) }
        if itemTextBytes > FeedResourcePolicy.maximumItemTextBytes { exceed(.itemTextLimit) }
    }

    private func exceed(_ reason: FeedIncompleteReason) {
        didExceedWorkBudget = true
        if incompleteReason == nil { incompleteReason = reason }
    }

    private func applyChannelValue(name: String, value: String) {
        switch name {
        case "title" where !isInsideMetadataContainer:
            channel.title = RSSTextEntityDecoder.decoded(value)
        case "description" where !isInsideMetadataContainer,
             "itunes:summary" where !isInsideMetadataContainer:
            if channel.summary.nilIfBlank == nil {
                channel.summary = value
            }
        case "link" where !isInsideMetadataContainer:
            channel.websiteURL = URL(string: value)
        case "itunes:author", "author":
            channel.author = RSSTextEntityDecoder.decoded(value)
        case "itunes:new-feed-url":
            channel.newFeedURL = URL(string: value)
        case "podcast:guid":
            channel.podcastGUID = value
        case "language":
            channel.language = value
        case "url" where elementStack.contains("image"):
            channel.artworkURL = URL(string: value)
        default:
            break
        }
    }

    /// A channel-level `<image>`/`<textinput>` closes before any `<item>`
    /// opens, so inside an item this only matches a (nonstandard) container
    /// nested in the item itself — spec-valid `<image><title>`/`<description>`
    /// must not steal channel or episode fields either way.
    private var isInsideMetadataContainer: Bool {
        elementStack.contains("image") || elementStack.contains("textinput")
    }

    private func pushNamespaceBindings(attributes: [String: String]) {
        var declaredPrefixes: [String] = []
        for (key, value) in attributes {
            let loweredKey = key.lowercased()
            guard loweredKey.hasPrefix("xmlns:") else {
                continue
            }
            let prefix = String(loweredKey.dropFirst("xmlns:".count))
            let isPodcastNamespace = Self.podcastNamespaceURIs.contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
            podcastPrefixBindings[prefix, default: []].append(isPodcastNamespace)
            declaredPrefixes.append(prefix)
        }
        declaredNamespacePrefixStack.append(declaredPrefixes)
    }

    private func popNamespaceBindings() {
        guard let declaredPrefixes = declaredNamespacePrefixStack.popLast() else {
            return
        }
        for prefix in declaredPrefixes {
            podcastPrefixBindings[prefix]?.removeLast()
            if podcastPrefixBindings[prefix]?.isEmpty == true {
                podcastPrefixBindings[prefix] = nil
            }
        }
    }

    private func isPodcastChaptersElement(_ name: String) -> Bool {
        guard name.hasSuffix(":chapters") else {
            return false
        }
        return podcastPrefixBindings[String(name.dropLast(":chapters".count))]?.last == true
    }

    private func captureEnclosure(attributes: [String: String]) {
        guard
            currentItem != nil,
            let audioURL = attributes.caseInsensitiveValue(for: "url").flatMap(URL.init(string:))
        else {
            return
        }

        let enclosureType = attributes.caseInsensitiveValue(for: "type")?.lowercased()
        let candidateIsAudio = enclosureType?.hasPrefix("audio/") == true
        let currentIsAudio = currentItem?.enclosureType?.hasPrefix("audio/") == true

        guard currentItem?.audioURL == nil || (candidateIsAudio && !currentIsAudio) else {
            return
        }

        currentItem?.audioURL = audioURL
        currentItem?.enclosureType = enclosureType
    }

    private func applyItemValue(name: String, value: String) {
        switch name {
        case "title" where !isInsideMetadataContainer:
            currentItem?.title = RSSTextEntityDecoder.decoded(value)
        case "guid":
            currentItem?.guid = value
        case "description" where !isInsideMetadataContainer,
             "itunes:summary" where !isInsideMetadataContainer:
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
    var language: String?
    var newFeedURL: URL?
    var podcastGUID: String?
}

struct ItemAccumulator: Codable {
    var title: String?
    var guid: String?
    var summary: String?
    var showNotesHTML: String?
    var publishedAt: Date?
    var duration: TimeInterval?
    var audioURL: URL?
    var enclosureType: String?
    var artworkURL: URL?
    var chaptersURL: URL?
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
