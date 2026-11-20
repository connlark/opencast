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

public struct AnalysisFrozenClock: AnalysisClock {
    public init() {}

    public func now() -> Double { 0 }

    public func sleep(seconds: Double) async throws {}
}
