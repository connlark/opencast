import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// UI tests: how the fixture transport answers every analysis send.
/// `OPENCAST_UI_TEST_ANALYSIS_TRANSPORT` picks the answer
/// (`fixture`, `invalid-key`, `rate-limited`, `trial-exhausted`,
/// `trial-paused`); `--opencast-ui-test-analysis-transport-hold` keeps every
/// send waiting until its run is cancelled.
nonisolated struct AnalysisUITestTransportMode: Sendable, Hashable {
    enum Answer: String, Sendable, Hashable {
        case fixture
        case invalidKey = "invalid-key"
        case rateLimited = "rate-limited"
        case trialExhausted = "trial-exhausted"
        case trialPaused = "trial-paused"
    }

    var answer: Answer
    var holds: Bool
}

/// Answers the pipeline from a synthetic reply built from the request's
/// own segments (the seeded transcript's sponsor read becomes one host-read
/// span), or with the scripted failure, and reports a send record for each
/// answer as a real transport does. Never reaches the network.
nonisolated struct AnalysisUITestFixtureTransport: AnalysisProviderTransport {
    let mode: AnalysisUITestTransportMode
    let route: AnalysisRoute
    let observer: any AnalysisProviderSendObserver

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        if mode.holds {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            record(request, status: nil, failure: nil, cancelled: true)
            throw .network
        }
        switch mode.answer {
        case .fixture:
            let body: String? = switch request.feature {
            case .adDetection: Self.adBody(for: request)
            case .chaptersSummary: ChaptersSummaryFixtureAnswer.geminiBody(for: request)
            }
            guard let body else {
                record(request, status: 400, failure: .requestRejected)
                throw .rejected(status: 400)
            }
            record(request, status: 200, failure: nil, usage: AnalysisBilledUsage(input: 420, cached: 0, write: 0, output: 36, reasoning: 0))
            return .geminiBody(body)
        case .invalidKey:
            record(request, status: 400, failure: .invalidKey)
            throw .rejected(status: 400)
        case .rateLimited:
            record(request, status: 429, failure: .dailyLimit)
            throw .quotaExhausted
        case .trialExhausted:
            record(request, status: 403, failure: .trialExhausted)
            throw .rejected(status: 403)
        case .trialPaused:
            record(request, status: 503, failure: .trialPaused)
            throw .rejected(status: 503)
        }
    }

    private func record(
        _ request: AnalysisProviderRequest,
        status: Int?,
        failure: AnalysisProviderFailure?,
        cancelled: Bool = false,
        usage: AnalysisBilledUsage? = nil
    ) {
        observer.record(AnalysisProviderSendRecord(
            provider: route == .trial ? .google : request.model.provider,
            modelID: request.model.modelID,
            feature: request.feature,
            purpose: request.purpose,
            sendIndex: request.sendIndex,
            status: status,
            finishReason: status == 200 ? .stop : nil,
            failure: failure,
            cancelled: cancelled,
            usage: usage,
            pacedSeconds: 0,
            exchangeSeconds: 0
        ))
    }

    /// A Gemini body whose answer names the window's first segment that
    /// reads "brought to you" as a host-read ad, or no spans.
    static func adBody(for request: AnalysisProviderRequest) -> String {
        var spans: [JSONValue] = []
        if let text = request.payload["contents"]?.arrayValue?.first?["parts"]?.arrayValue?.first?["text"]?.stringValue,
           let input = try? JSONParser.parse(text),
           let segments = input["segments"]?.arrayValue,
           let sponsor = segments.first(where: { $0["text"]?.stringValue?.contains("brought to you") == true }),
           case .number(let number)? = sponsor["id"],
           let sentence = sponsor["text"]?.stringValue {
            let words = sentence.split(separator: " ").map(String.init)
            spans.append(.object([
                JSONMember("confidence", .number(.double(0.92))),
                JSONMember("end_quote", .string(words.suffix(3).joined(separator: " "))),
                JSONMember("end_segment_id", .number(number)),
                JSONMember("evidence_quote", .string("brought to you")),
                JSONMember("kind", .string("host_read_ad")),
                JSONMember("label", .string("Sponsor read")),
                JSONMember("start_quote", .string(words.prefix(3).joined(separator: " "))),
                JSONMember("start_segment_id", .number(number)),
            ]))
        }
        let answer = JSONWriter.string(.object([JSONMember("spans", .array(spans))]))
        return JSONWriter.string(.object([
            JSONMember("candidates", .array([.object([
                JSONMember("content", .object([
                    JSONMember("parts", .array([.object([JSONMember("text", .string(answer))])])),
                    JSONMember("role", .string("model")),
                ])),
                JSONMember("finishReason", .string("STOP")),
            ])])),
            JSONMember("usageMetadata", .object([
                JSONMember("candidatesTokenCount", .integer(36)),
                JSONMember("promptTokenCount", .integer(420)),
                JSONMember("totalTokenCount", .integer(456)),
            ])),
        ]))
    }
}
