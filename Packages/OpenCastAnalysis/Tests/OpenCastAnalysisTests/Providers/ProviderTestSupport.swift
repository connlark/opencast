import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders

enum ProviderTestSupport {
    /// Runs CPU-bound test work on a Dispatch thread, off Swift
    /// concurrency's cooperative pool, and hands the result back for the
    /// test to check. A test that computes for seconds on a pool thread
    /// holds that thread the whole time; a few at once starve every timer
    /// in the process, and a 0.2 s deadline in another test fires seconds
    /// late.
    /// The CPU time this thread has used, in seconds. Linearity bounds
    /// compare work, so they read this rather than the wall clock: on a
    /// machine running other suites, a measurement on the wall clock also
    /// counts the time the thread waited to run.
    static func threadCPUSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) * 1e-9
    }

    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static var googleEndpoint: AnalysisProviderEndpoint { AnalysisPolicyBundle.baked.providers[.google]! }
    static var openAIEndpoint: AnalysisProviderEndpoint { AnalysisPolicyBundle.baked.providers[.openai]! }

    static var carouselRequest: AdAnalysisRequest {
        get throws {
            let text = try TestSupport.repositoryText("Server/AdAnalysisWorker/eval/fixtures/promo-carousel.json")
            return try AdAnalysisRequest(json: try JSONParser.parse(text))
        }
    }

    static func googleEntry() -> AnalysisModelEntry {
        AnalysisPolicyBundle.baked.features.adDetection.qualifiedModels.first { $0.provider == .google }!
    }

    static func openAIEntry() -> AnalysisModelEntry {
        AnalysisPolicyBundle.baked.features.adDetection.qualifiedModels.first { $0.provider == .openai }!
    }

    /// The carousel's first ad-detection window as a pipeline request.
    static func adWindowRequest(model: AnalysisModelEntry, timeout: Double = 120, sendIndex: Int = 0) throws -> AnalysisProviderRequest {
        let settings = AnalysisPolicyBundle.baked.features.adDetection
        let payload = AdCanonicalPayload.payload(
            try carouselRequest,
            policy: settings,
            maxOutputTokens: model.maxOutputTokens,
            thinking: model.thinking
        )
        return AnalysisProviderRequest(
            feature: .adDetection,
            purpose: .adWindow(index: 0),
            model: model,
            payload: payload,
            payloadText: JSONWriter.string(payload),
            thinking: model.thinking,
            timeoutSeconds: timeout,
            sendIndex: sendIndex
        )
    }

    static func googleTransport(
        _ client: ScriptedHTTPClient,
        pacer: AnalysisKeyPacer? = nil,
        observer: (any AnalysisProviderSendObserver)? = nil,
        sink: CollectingLogSink? = nil,
        clock: any AnalysisClock = AnalysisFrozenClock()
    ) throws -> GeminiAnalysisTransport {
        try GeminiAnalysisTransport(
            endpoint: googleEndpoint,
            key: ProviderTestKeys.google,
            client: client,
            pacer: pacer,
            observer: observer,
            logger: RedactingLogger(subsystem: nil, sink: sink),
            clock: clock
        )
    }

    static func openAITransport(
        _ client: ScriptedHTTPClient,
        pacer: AnalysisKeyPacer? = nil,
        observer: (any AnalysisProviderSendObserver)? = nil,
        sink: CollectingLogSink? = nil,
        clock: any AnalysisClock = AnalysisFrozenClock()
    ) throws -> OpenAIAnalysisTransport {
        try OpenAIAnalysisTransport(
            endpoint: openAIEndpoint,
            key: ProviderTestKeys.openAI,
            client: client,
            pacer: pacer,
            observer: observer,
            logger: RedactingLogger(subsystem: nil, sink: sink),
            clock: clock
        )
    }

    /// A provider fixture file under `Fixtures/providers/`.
    static func providerFixture(_ name: String) throws -> JSONValue {
        try TestSupport.fixture("providers/\(name)")
    }

    static func providerFixtureText(_ name: String) throws -> String {
        try String(
            contentsOf: TestSupport.packageRoot.appending(path: "Tests/OpenCastAnalysisTests/Fixtures/providers/\(name)"),
            encoding: .utf8
        )
    }

    static func sendResult(_ transport: some AnalysisProviderTransport, _ request: AnalysisProviderRequest) async -> Result<AnalysisProviderReply, AnalysisTransportError> {
        do {
            return .success(try await transport.send(request))
        } catch {
            return .failure(error)
        }
    }
}
