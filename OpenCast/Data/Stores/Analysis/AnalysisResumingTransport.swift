import OpenCastAnalysis

/// Wraps a run's transport so a resumed run answers the requests its
/// earlier attempt already had answered from the kept replies, and sends
/// only the rest. Every reply the provider gives is kept for a later resume
/// of the same run. The pipeline is a pure function of the request bytes
/// and the replies, so a reply reused for byte-identical request bytes
/// yields what the earlier attempt computed.
nonisolated struct AnalysisResumingTransport: AnalysisProviderTransport {
    let inner: any AnalysisProviderTransport
    let store: AnalysisRunRecordStore
    let runID: String
    /// The replies kept when the run started (empty for a new run).
    let kept: [AnalysisRunReplyKey: AnalysisRunStoredReply]
    /// Told about each request answered from the kept replies.
    let onReused: @Sendable (AnalysisProviderRequest) -> Void

    init(
        inner: any AnalysisProviderTransport,
        store: AnalysisRunRecordStore,
        runID: String,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void = { _ in }
    ) {
        self.inner = inner
        self.store = store
        self.runID = runID
        kept = store.replies(runID: runID)
        self.onReused = onReused
    }

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        let key = AnalysisRunReplyKey(request)
        if let stored = kept[key] {
            onReused(request)
            return stored.reply
        }
        let reply = try await inner.send(request)
        store.saveReply(AnalysisRunStoredReply(reply), for: key, runID: runID)
        return reply
    }
}
