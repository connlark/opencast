import Foundation

extension RSSFeedParser {
    /// Blocking file and XML work belongs to the preparation task's concurrent
    /// executor. Original and recovery attempts have independent SQLite stores.
    @concurrent
    public func prepare(fileURL: URL, feedURL: URL, transferIssue: FeedIncompleteReason? = nil) async throws -> PreparedFeed {
        let workspace = try FeedWorkspace()
        let original = try attempt(fileURL: fileURL, feedURL: feedURL, workspace: workspace, name: "original.sqlite")
        var selected = original
        if original.error != nil, original.streamIssue == nil, !original.delegate.didExceedWorkBudget {
            let recoveredURL = workspace.file("recovered.xml")
            if try RSSFeedRecovery.recoverFile(from: fileURL, to: recoveredURL) {
                let recovered = try attempt(fileURL: recoveredURL, feedURL: feedURL, workspace: workspace, name: "recovered.sqlite")
                if recovered.error == nil || recovered.delegate.itemCount > selected.delegate.itemCount
                    || (recovered.delegate.itemCount == selected.delegate.itemCount
                        && recovered.delegate.incompleteReason != nil && selected.delegate.incompleteReason == nil) {
                    selected = recovered
                }
            }
        }
        try Task.checkCancellation()
        if selected.delegate.itemCount == 0,
           transferIssue == .decodedByteLimit || selected.streamIssue == .decodedByteLimit {
            throw OpenCastCoreError.feedTooLarge(byteLimit: FeedResourcePolicy.maximumDecodedBytes)
        }
        guard let root = selected.delegate.rootElementName, ["rss", "rdf:rdf", "rdf"].contains(root) else {
            throw OpenCastCoreError.notAFeed(rootElement: selected.delegate.rootElementName ?? "")
        }
        let reason = transferIssue ?? selected.streamIssue ?? selected.delegate.incompleteReason
            ?? selected.error.map { .malformedXML($0.localizedDescription) }
        if reason != nil, selected.delegate.itemCount == 0 {
            throw OpenCastCoreError.malformedFeed(reason: reason?.diagnostic)
        }
        let podcast = selected.delegate.podcastMetadata
        let episodes = try selected.stager.finish(podcast: podcast)
        return PreparedFeed(podcast: podcast, completeness: reason.map(FeedCompleteness.partial) ?? .complete,
                            newFeedURL: selected.delegate.newFeedURL, episodes: episodes)
    }

    private func attempt(fileURL: URL, feedURL: URL, workspace: FeedWorkspace, name: String) throws -> RSSStagedAttempt {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        let prefix = try handle.read(upToCount: 1_024) ?? Data()
        try handle.close()
        let stager = try RSSItemStager(feedURL: feedURL, workspace: workspace, name: name)
        let delegate = FeedXMLParserDelegate(feedURL: feedURL,
            fallbackCDATAEncoding: RSSFeedRecovery.declaredEncoding(in: prefix), itemSink: stager.append)
        let stream = try FeedXMLInputStream(fileURL: fileURL,
            maximumBytes: name == "recovered.sqlite" ? FeedResourcePolicy.maximumProcessingBytes : FeedResourcePolicy.maximumDecodedBytes)
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
