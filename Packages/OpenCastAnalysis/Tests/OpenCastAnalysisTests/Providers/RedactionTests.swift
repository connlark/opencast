import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// No header value and no fragment of a key reaches a thrown error's
/// description, a log line or a recorded fixture.
@Suite("Redaction")
struct RedactionTests {
    static let echoedFragment = "ECHOED-REQUEST-FRAGMENT"

    @Test("Keys, headers and requests never print their secret values")
    func valuesNeverPrint() throws {
        let request = try #require(try ProviderTestSupport.googleTransport(ScriptedHTTPClient([]))
            .generateRequest(try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.googleEntry())))
        let openAI = try #require(try ProviderTestSupport.openAITransport(ScriptedHTTPClient([]))
            .generateRequest(try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.openAIEntry())))
        for value in [String(describing: ProviderTestKeys.google), String(reflecting: ProviderTestKeys.openAI),
                      String(describing: request), String(reflecting: request), String(describing: openAI),
                      String(describing: request.headers), String(reflecting: openAI.headers),
                      Self.dump(ProviderTestKeys.google), Self.dump(request), Self.dump(openAI)] {
            #expect(!ProviderTestKeys.leaks(in: value), "\(value)")
            #expect(!value.contains("Bearer"))
        }
        let response = AnalysisHTTPResponse(status: 400, body: Data(Self.echoedFragment.utf8))
        #expect(!String(describing: response).contains(Self.echoedFragment))
        #expect(!Self.dump(response).contains(Self.echoedFragment))
    }

    @Test("Transports, loggers and runners holding a key never print it")
    func holdersNeverPrint() throws {
        let gemini = try ProviderTestSupport.googleTransport(ScriptedHTTPClient([]))
        let openAI = try ProviderTestSupport.openAITransport(ScriptedHTTPClient([]))
        let logger = RedactingLogger(subsystem: nil, secrets: [ProviderTestKeys.googleText])
        let runner = AnalysisRunner(transport: gemini)
        let values: [Any] = [gemini, openAI, logger, runner, logger.redacting(ProviderTestKeys.openAIText)]
        for value in values {
            for text in [String(describing: value), String(reflecting: value), Self.dump(value)] {
                #expect(!ProviderTestKeys.leaks(in: text), "\(text)")
            }
        }
    }

    @Test("The logger removes registered secrets, key shapes and credential headers")
    func loggerScrubs() {
        let sink = CollectingLogSink()
        let logger = RedactingLogger(subsystem: nil, secrets: ["s3cr3t-value"], sink: sink)
        logger.log("a s3cr3t-value b")
        logger.log("google \(ProviderTestKeys.googleText) openai \(ProviderTestKeys.openAIText)")
        logger.log("x-goog-api-key: anything-at-all authorization: Bearer token-value-123 x-api-key=zzz")
        logger.log("AQ." + String(repeating: "Ab9", count: 8) + " pplx-" + String(repeating: "q", count: 30))
        let lines = sink.all
        #expect(lines[0] == "a [REDACTED] b")
        #expect(!ProviderTestKeys.leaks(in: lines[1]))
        #expect(!lines[2].contains("anything-at-all") && !lines[2].contains("token-value-123") && !lines[2].contains("zzz"))
        #expect(!lines[3].contains("Ab9Ab9") && !lines[3].contains("qqqqqqqq"))
    }

    @Test("Across every error case, no key fragment or provider body reaches errors, records or log lines")
    func errorPathsStayClean() async throws {
        let fixture = try ProviderTestSupport.providerFixture("error-cases.json")
        let answers = try ProviderTestSupport.providerFixture("answer-cases.json")
        var exchanges: [(AnalysisProvider, ScriptedHTTPClient.Step)] = []
        for item in fixture["cases"]?.arrayValue ?? [] {
            let provider = try #require(AnalysisProvider(rawValue: item["provider"]?.stringValue ?? ""))
            if let status = item["status"].flatMap({ ProviderJSON.count($0) }), let body = item["body"]?.stringValue {
                let echoing = body.replacing("API key", with: "API key \(Self.echoedFragment) \(ProviderTestKeys.googleText)")
                exchanges.append((provider, .respond(AnalysisHTTPResponse(status: Int(status), retryAfter: item["retry_after"]?.stringValue, body: Data(echoing.utf8)))))
            }
        }
        for item in answers["cases"]?.arrayValue ?? [] {
            let provider = try #require(AnalysisProvider(rawValue: item["provider"]?.stringValue ?? ""))
            let body = (item["body"]?.stringValue ?? "").replacing("Harbor", with: Self.echoedFragment)
            exchanges.append((provider, .respond(AnalysisHTTPResponse(status: 200, body: Data(body.utf8)))))
        }
        exchanges += [(.google, .fail(.timeout)), (.openai, .fail(.network)), (.google, .fail(.oversizedBody))]
        exchanges.append((.openai, .respond(AnalysisHTTPResponse(status: 200, body: Data([0xFF, 0x00])))))

        for (provider, step) in exchanges {
            let sink = CollectingLogSink()
            let log = AnalysisProviderSendLog()
            let client = ScriptedHTTPClient(Array(repeating: step, count: 40))
            let transport = try ProviderErrorTableTests.transport(provider, client, observer: log, sink: sink)
            let runner = AnalysisRunner(transport: transport, clock: AnalysisFrozenClock())
            let entry = ProviderErrorTableTests.entry(provider)
            let outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: entry))
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: entry))
            var texts = sink.all + log.sends.map { String(describing: $0) } + Self.failureTexts(outcome)
            if case .failed = outcome { texts += [String(describing: outcome), String(reflecting: outcome)] }
            if case .failure(let error) = result { texts += [String(describing: error), String(reflecting: error)] }
            #expect(!texts.isEmpty)
            for text in texts {
                #expect(!ProviderTestKeys.leaks(in: text), "\(text)")
                #expect(!text.contains(Self.echoedFragment), "\(text)")
                #expect(!text.contains("Bearer"), "\(text)")
            }
        }
    }

    @Test("Recorded and constructed fixtures carry no key material")
    func fixturesAreClean() throws {
        let directory = TestSupport.packageRoot.appending(path: "Tests/OpenCastAnalysisTests/Fixtures/providers")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(!names.isEmpty)
        for name in names {
            let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            #expect(RedactingLogger.redact(text) == text, "\(name) holds a key-shaped value")
            #expect(!ProviderTestKeys.leaks(in: text), "\(name)")
            #expect(!text.lowercased().contains("x-goog-api-key\":"), "\(name)")
            #expect(!text.contains("Bearer "), "\(name)")
        }
    }

    static func dump(_ value: Any) -> String {
        var text = ""
        Swift.dump(value, to: &text)
        return text
    }

    static func failureTexts(_ outcome: AnalysisOutcome) -> [String] {
        guard case .failed(let failure) = outcome else { return [] }
        return [JSONWriter.string(failure.errorJSON()), failure.detail ?? "", failure.issues.joined(separator: ",")]
    }
}

extension RedactionTests {
    /// A synthetic OpenAI key and the masked echo OpenAI's invalid-key error
    /// makes of it (prefix, a run of asterisks, the last four characters).
    static let maskedKeySuffix = "Zq4W"
    static let maskedKey = "sk-" + "proj-" + String(repeating: "Lm2N", count: 10) + maskedKeySuffix
    static let maskedEcho = #"{"error":{"message":"Incorrect API key provided: sk-proj-************************************"#
        + maskedKeySuffix
        + #". You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#
    static let finishCanary = "FINISH-REASON-CANARY"
    static let retryCanary = "RETRY-AFTER-CANARY"

    @Test("Finish reasons from a provider never carry text into send records, answers or log lines")
    func finishReasonsCarryNoText() async throws {
        let googleReason = "\(Self.finishCanary)-\(ProviderTestKeys.googleText)"
        let openAIReason = "\(Self.finishCanary)-\(ProviderTestKeys.openAIText)"
        let gemini = JSONWriter.string(.object([
            "candidates": .array([.object([
                "content": .object(["parts": .array([.object(["text": .string("{\"spans\":[]}")])]), "role": .string("model")]),
                "finishReason": .string(googleReason),
            ])]),
            "usageMetadata": .object(["promptTokenCount": .integer(10), "candidatesTokenCount": .integer(5), "totalTokenCount": .integer(15)]),
        ]))
        let openAIStatus = JSONWriter.string(.object([
            "object": .string("response"), "status": .string(openAIReason), "output": .array([]),
        ]))
        let openAIIncomplete = JSONWriter.string(.object([
            "object": .string("response"), "status": .string("incomplete"),
            "incomplete_details": .object(["reason": .string(openAIReason)]), "output": .array([]),
        ]))
        let openAIMessage = JSONWriter.string(.object([
            "object": .string("response"), "status": .string("completed"), "error": .null, "incomplete_details": .null,
            "output": .array([.object([
                "type": .string("message"), "status": .string(openAIReason),
                "content": .array([.object(["type": .string("output_text"), "text": .string("{\"spans\":[]}")])]),
            ])]),
        ]))
        for (provider, body) in [(AnalysisProvider.google, gemini), (.openai, openAIStatus), (.openai, openAIIncomplete), (.openai, openAIMessage)] {
            let sink = CollectingLogSink()
            let log = AnalysisProviderSendLog()
            let transport = try ProviderErrorTableTests.transport(provider, ScriptedHTTPClient(status: 200, body: body), observer: log, sink: sink)
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: ProviderErrorTableTests.entry(provider)))
            var texts = sink.all + log.sends.flatMap { [String(describing: $0), String(reflecting: $0), Self.dump($0)] }
            if case .success(.answer(let answer)) = result {
                texts += [answer.finishReason ?? "", String(describing: answer)]
            }
            #expect(log.sends.count == 1)
            #expect(log.sends.first?.finishReason == .malformedResponse || log.sends.first?.finishReason == .incomplete, "\(provider)")
            if case .success(.answer(let answer)) = result {
                #expect(AnalysisFinishReason(rawValue: answer.finishReason ?? "") != nil)
            }
            #expect(!texts.isEmpty)
            for text in texts {
                #expect(!text.contains(Self.finishCanary), "\(provider): \(text)")
                #expect(!ProviderTestKeys.leaks(in: text), "\(provider): \(text)")
            }
        }
    }

    @Test("A response's Retry-After is never reflected raw")
    func retryAfterIsNotReflected() {
        let response = AnalysisHTTPResponse(status: 429, retryAfter: Self.retryCanary, body: Data())
        for text in [String(describing: response), String(reflecting: response), Self.dump(response)] {
            #expect(!text.contains(Self.retryCanary), "\(text)")
        }
        #expect(response.retryAfterSeconds == nil)
        #expect(AnalysisHTTPResponse(status: 429, retryAfter: "45", body: Data()).retryAfterSeconds == 30)
        #expect(AnalysisHTTPResponse(status: 429, retryAfter: " 7 ", body: Data()).retryAfter == "7")
    }
}
