import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Synchronization
import Testing

@Suite("Transport pacing")
struct TransportPacingTests {
    @Test("A 429 seen by one transport paces every transport on the key, and a paced refusal reads as rate limited")
    func transportsSharePacing() async throws {
        let clock = ManualClock()
        let pacing = AnalysisKeyPacing(clock: clock)
        let model = ProviderTestSupport.googleEntry()
        let limited = ScriptedHTTPClient(status: 429, body: #"{"error":{"code":429,"message":"slow down","status":"RESOURCE_EXHAUSTED"}}"#, retryAfter: "20")
        let first = try ProviderTestSupport.googleTransport(
            limited,
            pacer: pacing.pacer(provider: .google, key: ProviderTestKeys.google, maxInFlight: 4),
            clock: clock
        )
        let result = await ProviderTestSupport.sendResult(first, try ProviderTestSupport.adWindowRequest(model: model))
        #expect(result == .failure(.retryable(status: 429, retryAfterSeconds: 20)))

        let log = AnalysisProviderSendLog()
        let second = try ProviderTestSupport.googleTransport(
            ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}")),
            pacer: pacing.pacer(provider: .google, key: ProviderTestKeys.google, maxInFlight: 4),
            observer: log,
            clock: clock
        )
        let refused = await ProviderTestSupport.sendResult(second, try ProviderTestSupport.adWindowRequest(model: model, timeout: 10))
        #expect(refused == .failure(.timeout))
        #expect(log.sends.last?.failure == .rateLimited)

        let waiting = Task { await ProviderTestSupport.sendResult(second, try! ProviderTestSupport.adWindowRequest(model: model, timeout: 60)) }
        await clock.waitForSleepers()
        clock.advance(by: 20)
        #expect(await waiting.value == .success(.geminiBody(TestSupport.geminiBody("{}"))))
        #expect(log.sends.last?.pacedSeconds == 20)
    }

    @Test("Time spent waiting for the key comes out of the request's deadline")
    func pacingSharesTheDeadline() async throws {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        await pacer.noteRateLimited(retryAfterSeconds: 15)
        let client = ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}"))
        let transport = try ProviderTestSupport.googleTransport(client, pacer: pacer, clock: clock)
        let sending = Task { await ProviderTestSupport.sendResult(transport, try! ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.googleEntry(), timeout: 60)) }
        await clock.waitForSleepers()
        clock.advance(by: 15)
        _ = await sending.value
        #expect(client.timeouts == [45])
        #expect(await pacer.admit(deadline: clock.now() + 1) == .admitted(waitedSeconds: 0))
    }

    @Test("A queued request never starts inside the cooldown of the 429 that freed its slot")
    func rateLimitAppliesBeforeTheSlotFrees() async throws {
        for _ in 0..<20 {
            let clock = ManualClock()
            let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
            let client = GatedHTTPClient()
            let gated = try GeminiAnalysisTransport(
                endpoint: ProviderTestSupport.googleEndpoint, key: ProviderTestKeys.google,
                client: client, pacer: pacer, logger: RedactingLogger(subsystem: nil), clock: clock
            )
            let model = ProviderTestSupport.googleEntry()
            let first = Task { await ProviderTestSupport.sendResult(gated, try! ProviderTestSupport.adWindowRequest(model: model, timeout: 100)) }
            await client.waitForWaiting(1)
            let second = Task { await ProviderTestSupport.sendResult(gated, try! ProviderTestSupport.adWindowRequest(model: model, timeout: 100)) }
            await clock.waitForSleepers(1)
            client.answer(.respond(AnalysisHTTPResponse(
                status: 429,
                retryAfter: "20",
                body: Data(#"{"error":{"code":429,"message":"slow down","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
            )))
            #expect(await first.value == .failure(.retryable(status: 429, retryAfterSeconds: 20)))
            // The queued send must now be asleep until the cooldown ends, not
            // sending. Advancing before it registers that sleep would leave it
            // asleep past the advance for good.
            #expect(await eventually { clock.wakeTimes.contains(20) })
            #expect(client.sentCount == 1)
            clock.advance(by: 20)
            await client.waitForWaiting(1)
            #expect(client.sentCount == 2)
            client.answer(.respond(AnalysisHTTPResponse(status: 200, body: Data(TestSupport.geminiBody("{}").utf8))))
            #expect(await second.value == .success(.geminiBody(TestSupport.geminiBody("{}"))))
        }
    }

    @Test("The pre-dispatch check runs once the pacer admits a send; its refusal sends nothing, records why and frees the slot")
    func preDispatchCheckAfterAdmission() async throws {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        #expect(await pacer.admit(deadline: clock.now() + 100) == .admitted(waitedSeconds: 0))
        let refuses = Mutex(false)
        let checks = Mutex(0)
        let client = ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}"))
        let log = AnalysisProviderSendLog()
        let transport = try GeminiAnalysisTransport(
            endpoint: ProviderTestSupport.googleEndpoint, key: ProviderTestKeys.google,
            client: client, pacer: pacer, observer: log, logger: RedactingLogger(subsystem: nil), clock: clock,
            preDispatch: {
                checks.withLock { $0 += 1 }
                let refused = refuses.withLock { $0 }
                return refused ? AnalysisProviderErrorClassification(transport: .rejected(status: 0), listener: .keyRequired) : nil
            }
        )
        let model = ProviderTestSupport.googleEntry()

        // Queued behind the held slot: nothing checked yet.
        let waiting = Task { await ProviderTestSupport.sendResult(transport, try! ProviderTestSupport.adWindowRequest(model: model, timeout: 60)) }
        await clock.waitForSleepers()
        #expect(checks.withLock { $0 } == 0)
        refuses.withLock { $0 = true }
        await pacer.release()

        #expect(await waiting.value == .failure(.rejected(status: 0)))
        #expect(checks.withLock { $0 } == 1)
        #expect(client.requests.isEmpty)
        #expect(log.sends.map(\.failure) == [.keyRequired])
        #expect(log.sends.first?.status == nil)
        #expect(await pacer.admit(deadline: clock.now() + 1) == .admitted(waitedSeconds: 0))
        await pacer.release()

        // A check that lets the send go changes nothing.
        refuses.withLock { $0 = false }
        let sent = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: model))
        #expect(sent == .success(.geminiBody(TestSupport.geminiBody("{}"))))
        #expect(client.requests.count == 1)
        #expect(checks.withLock { $0 } == 2)
    }

    @Test("A send the run cancels is recorded as cancelled, with no listener failure")
    func cancelledSendRecord() async throws {
        let client = GatedHTTPClient()
        let log = AnalysisProviderSendLog()
        let transport = try GeminiAnalysisTransport(
            endpoint: ProviderTestSupport.googleEndpoint, key: ProviderTestKeys.google,
            client: client, observer: log, logger: RedactingLogger(subsystem: nil), clock: AnalysisFrozenClock()
        )
        let sending = Task { await ProviderTestSupport.sendResult(transport, try! ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.googleEntry())) }
        await client.waitForWaiting(1)
        sending.cancel()
        #expect(await sending.value == .failure(.network))
        #expect(log.sends.count == 1)
        #expect(log.sends.first?.cancelled == true)
        #expect(log.sends.first?.failure == nil)
    }
}

extension TransportPacingTests {
    static func quotaCase(_ name: String) throws -> ScriptedHTTPClient.Step {
        try #require(try GeminiQuotaDetailsTests.cases().first { $0.name == name }).step
    }

    @Test("A Gemini per-minute 429 flips the key to serial and holds the next send for its RetryInfo delay")
    func perMinuteQuotaPaces() async throws {
        let clock = ManualClock()
        let pacing = AnalysisKeyPacing(clock: clock)
        let model = ProviderTestSupport.googleEntry()
        let pacer = pacing.pacer(provider: .google, key: ProviderTestKeys.google, maxInFlight: 4)
        let first = try ProviderTestSupport.googleTransport(ScriptedHTTPClient([try Self.quotaCase("minute-retry-info")]), pacer: pacer, clock: clock)
        let limited = await ProviderTestSupport.sendResult(first, try ProviderTestSupport.adWindowRequest(model: model))
        #expect(limited == .failure(.retryable(status: 429, retryAfterSeconds: 12)))
        #expect(await pacer.isSerial)

        let log = AnalysisProviderSendLog()
        let second = try ProviderTestSupport.googleTransport(
            ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}")), pacer: pacer, observer: log, clock: clock
        )
        let waiting = Task { await ProviderTestSupport.sendResult(second, try! ProviderTestSupport.adWindowRequest(model: model, timeout: 60)) }
        await clock.waitForSleepers()
        #expect(log.sends.isEmpty)
        clock.advance(by: 12)
        #expect(await waiting.value == .success(.geminiBody(TestSupport.geminiBody("{}"))))
        #expect(log.sends.last?.pacedSeconds == 12)
    }

    @Test("A Gemini per-day 429 does not pace the key, and the run fails as a daily limit")
    func perDayQuotaIsFinal() async throws {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 4, clock: clock)
        let log = AnalysisProviderSendLog()
        let step = try Self.quotaCase("daily-with-one-second-retry-info")
        let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(Array(repeating: step, count: 10)), pacer: pacer, observer: log, clock: clock)
        let outcome = await AnalysisRunner(transport: transport, clock: clock)
            .detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: ProviderTestSupport.googleEntry()))
        guard case .failed(let failure) = outcome else {
            Issue.record("a daily limit did not fail the run: \(outcome)")
            return
        }
        #expect(failure.code == .quotaExhausted)
        #expect(AnalysisProviderFailure.resolve(outcome, sends: log.sends)?.rawValue == "daily_limit")
        #expect(await !pacer.isSerial)
        #expect(log.sends.count == 1)
    }
}

extension TransportPacingTests {
    @Test("A request with a huge or non-finite timeout is paced and sent without trapping")
    func hugeRequestTimeout() async throws {
        for timeout in [1e300, Double.infinity, Double.nan] {
            let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: AnalysisSystemClock())
            let client = ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}"))
            let transport = try ProviderTestSupport.googleTransport(client, pacer: pacer, clock: AnalysisSystemClock())
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.googleEntry(), timeout: timeout))
            if timeout.isNaN {
                #expect(result == .failure(.timeout))
            } else {
                #expect(result == .success(.geminiBody(TestSupport.geminiBody("{}"))))
                #expect((client.timeouts.first ?? 0) <= 86_400)
            }
        }
    }
}
