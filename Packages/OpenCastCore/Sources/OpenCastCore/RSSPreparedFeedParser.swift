import Foundation

extension RSSFeedParser {
    /// Blocking file and XML work belongs to the preparation task's concurrent
    /// executor. Original and recovery attempts have independent SQLite stores.
    @concurrent
    public func prepare(fileURL: URL, feedURL: URL, transferIssue: FeedIncompleteReason? = nil) async throws -> PreparedFeed {
        try await prepare(
            fileURL: fileURL,
            feedURL: feedURL,
            transferIssue: transferIssue,
            attemptObserver: nil
        )
    }

    @concurrent
    func prepare(
        fileURL: URL,
        feedURL: URL,
        transferIssue: FeedIncompleteReason? = nil,
        attemptObserver: (@Sendable () -> Void)?
    ) async throws -> PreparedFeed {
        attemptObserver?()
        let original = try attempt(
            fileURL: fileURL,
            feedURL: feedURL,
            isRecoveredInput: false
        )
        var selected = original
        if original.error != nil, original.streamIssue == nil, original.delegate.isRecoveryEligible {
            let recoveredInput = try FeedWorkspace()
            defer { recoveredInput.discard() }
            let recoveredURL = recoveredInput.file("recovered.xml")
            if try RSSFeedRecovery.recoverFile(from: fileURL, to: recoveredURL) {
                attemptObserver?()
                let recovered = try attempt(
                    fileURL: recoveredURL,
                    feedURL: feedURL,
                    isRecoveredInput: true
                )
                let selectedHasSpecificIssue = selected.streamIssue != nil
                    || selected.delegate.incompleteReason != nil
                let recoveredHasSpecificIssue = recovered.streamIssue != nil
                    || recovered.delegate.incompleteReason != nil
                if recovered.error == nil || recovered.delegate.itemCount > selected.delegate.itemCount
                    || (recovered.delegate.itemCount == selected.delegate.itemCount
                        && recoveredHasSpecificIssue && !selectedHasSpecificIssue) {
                    selected.stager.discard()
                    selected = recovered
                } else {
                    recovered.stager.discard()
                }
            }
        }
        defer { selected.stager.discard() }
        try Task.checkCancellation()
        if selected.delegate.itemCount == 0,
           transferIssue == .decodedByteLimit || selected.streamIssue == .decodedByteLimit {
            throw OpenCastCoreError.feedTooLarge(byteLimit: FeedResourcePolicy.maximumDecodedBytes)
        }
        let reason = transferIssue ?? selected.streamIssue ?? selected.delegate.incompleteReason
            ?? selected.error.map { .malformedXML($0.localizedDescription) }
        if let reason, selected.delegate.itemCount == 0,
           transferIssue != nil || selected.streamIssue != nil {
            throw OpenCastCoreError.incompleteFeed(reason: reason)
        }
        guard let root = selected.delegate.rootElementName, ["rss", "rdf:rdf", "rdf"].contains(root) else {
            throw OpenCastCoreError.notAFeed(rootElement: selected.delegate.rootElementName ?? "")
        }
        if let reason, selected.delegate.itemCount == 0 {
            throw OpenCastCoreError.incompleteFeed(reason: reason)
        }
        let podcast = selected.delegate.podcastMetadata
        let episodes = try selected.stager.finish(podcast: podcast)
        return PreparedFeed(podcast: podcast, completeness: reason.map(FeedCompleteness.partial) ?? .complete,
                            newFeedURL: selected.delegate.newFeedURL, episodes: episodes)
    }

    private func attempt(
        fileURL: URL,
        feedURL: URL,
        isRecoveredInput: Bool
    ) throws -> RSSStagedAttempt {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        let prefix = try handle.read(upToCount: 1_024) ?? Data()
        try handle.close()
        let stager = try RSSItemStager(feedURL: feedURL)
        let delegate = FeedXMLParserDelegate(feedURL: feedURL,
            fallbackCDATAEncoding: RSSFeedRecovery.declaredEncoding(in: prefix), itemSink: stager.append)
        let stream = try FeedXMLInputStream(fileURL: fileURL,
            maximumBytes: isRecoveredInput
                ? FeedResourcePolicy.maximumProcessingBytes
                : FeedResourcePolicy.maximumDecodedBytes)
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let success = parser.parse()
        let inputError = stream.streamError
        stream.close()
        try Task.checkCancellation()
        if let error = delegate.sinkError { throw error }
        if let inputError, stream.incompleteReason == nil { throw inputError }
        return RSSStagedAttempt(delegate: delegate, stager: stager,
            error: success ? nil : parser.parserError ?? OpenCastCoreError.malformedFeed(reason: nil),
            streamIssue: stream.incompleteReason)
    }
}

private struct RSSStagedAttempt {
    let delegate: FeedXMLParserDelegate
    let stager: RSSItemStager
    let error: (any Error)?
    let streamIssue: FeedIncompleteReason?
}
