import OpenCastAnalysis

/// Reusing a kept reply is sound because the pipeline is a pure function of the request bytes and
/// the replies: a byte-identical request yields what the earlier attempt computed.
nonisolated struct AnalysisResumingTransport: AnalysisProviderTransport {
    let inner: any AnalysisProviderTransport
    let store: AnalysisRunRecordStore
    let runID: String
    let kept: [AnalysisRunReplyKey: AnalysisRunStoredReply]
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
