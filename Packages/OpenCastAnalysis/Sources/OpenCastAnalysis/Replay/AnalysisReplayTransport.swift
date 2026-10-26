/// A transport that serves recorded answers instead of calling a provider:
/// how archived model answers are replayed through the pipeline. A request
/// with no recorded answer fails with ``AnalysisTransportError/notArchived``.
public struct AnalysisReplayTransport: AnalysisProviderTransport {
    public let replies: [AnalysisProviderRequest.Purpose: AnalysisProviderReply]

    public init(replies: [AnalysisProviderRequest.Purpose: AnalysisProviderReply]) {
        self.replies = replies
    }

    public func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        guard let reply = replies[request.purpose] else { throw .notArchived }
        return reply
    }
}

/// A clock that stands still and never waits, so a replay never runs out of
/// budget and never sleeps.
public struct AnalysisFrozenClock: AnalysisClock {
    public init() {}

    public func now() -> Double { 0 }

    public func sleep(seconds: Double) async throws {}
}
