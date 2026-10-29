import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
@testable import OpenCastAnalysisReplay
import Testing

/// The live tool's recorder and spend hook: what they save and how long
/// they may hold an exchange.
@Suite("Replay tool live recording")
struct ReplayToolTests {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "opencast-replay-tool-\(UUID().uuidString)")
    }

    /// Every file the recorder wrote, as text.
    static func recordedTexts(_ directory: URL) throws -> [String] {
        let exchanges = directory.appending(path: "exchanges")
        return try FileManager.default.contentsOfDirectory(atPath: exchanges.path(percentEncoded: false)).sorted().map {
            try String(contentsOf: exchanges.appending(path: $0), encoding: .utf8)
        }
    }

    /// An executable shell script under `directory`.
    static func script(_ directory: URL, _ body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "hook-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    static func recorder(
        _ inner: any AnalysisHTTPClient,
        directory: URL,
        key: AnalysisProviderKey = ProviderTestKeys.openAI,
        hook: SpendHook? = nil
    ) throws -> RecordingHTTPClient {
        try RecordingHTTPClient(
            inner: inner,
            directory: directory,
            provider: .openai,
            model: ProviderTestSupport.openAIEntry(),
            key: key,
            hook: hook,
            maxGenerateSends: 5,
            context: [:]
        )
    }

    static func generateRequest() throws -> AnalysisHTTPRequest {
        try #require(try ProviderTestSupport.openAITransport(ScriptedHTTPClient([]))
            .generateRequest(try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.openAIEntry())))
    }

    @Test("The recorder saves no masked key echo or key suffix, and no log line carries one")
    func recorderRedactsMaskedEchoes() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AnalysisProviderKey(RedactionTests.maskedKey))
        let inner = ScriptedHTTPClient(status: 401, body: RedactionTests.maskedEcho)
        let sink = CollectingLogSink()
        let transport = try OpenAIAnalysisTransport(
            endpoint: ProviderTestSupport.openAIEndpoint,
            key: key,
            client: try Self.recorder(inner, directory: directory, key: key),
            logger: RedactingLogger(subsystem: nil, sink: sink),
            clock: AnalysisFrozenClock()
        )
        let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.openAIEntry()))
        #expect(result == .failure(.rejected(status: 401)))
        let texts = try Self.recordedTexts(directory) + sink.all
        #expect(texts.count >= 4)
        for text in texts {
            #expect(!text.contains(RedactionTests.maskedKeySuffix), "\(text)")
            #expect(!text.contains("****"), "\(text)")
        }
    }

    @Test("The recorder keeps only the parsed, capped Retry-After seconds")
    func recorderKeepsParsedRetryAfter() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = ScriptedHTTPClient([
            .respond(AnalysisHTTPResponse(status: 429, retryAfter: "45", body: Data("{}".utf8))),
            .respond(AnalysisHTTPResponse(status: 429, retryAfter: RedactionTests.retryCanary, body: Data("{}".utf8))),
        ])
        let recorder = try Self.recorder(inner, directory: directory)
        let request = try Self.generateRequest()
        for _ in 0..<2 {
            _ = try? await recorder.send(request, timeoutSeconds: 300, maximumBodyBytes: 1024)
        }
        let metas = try Self.recordedTexts(directory).filter { $0.contains("\"timeout_s\"") }
        #expect(metas.count == 2)
        #expect(metas.first?.contains(#""retry_after_s":30"#) == true, "\(metas)")
        for text in try Self.recordedTexts(directory) {
            #expect(!text.contains(RedactionTests.retryCanary), "\(text)")
            #expect(!text.contains(#""45""#), "\(text)")
        }
    }

    @Test("A sleeping spend hook stops promptly when its caller is cancelled")
    func hookStopsOnCancellation() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = SpendHook(executable: try Self.script(directory, "exec sleep \(Self.childLifetimeSeconds)"))
        let started = ContinuousClock.now
        let running = Task { await hook.run(["reserve"], timeoutSeconds: 2 * Double(Self.childLifetimeSeconds)) }
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()
        let reply = await running.value
        #expect(reply.ending == .cancelled)
        #expect(reply.status != 0)
        #expect(started.duration(to: .now) < .seconds(Self.childLifetimeSeconds))

        // A hook that ignores the polite stop is killed after the grace period.
        let stubborn = SpendHook(executable: try Self.script(
            directory, "trap '' TERM; i=0; while [ $i -lt \(Self.childLifetimeSeconds) ]; do sleep 1; i=$((i + 1)); done"))
        let stubbornStart = ContinuousClock.now
        let limited = await stubborn.run(["reserve"], timeoutSeconds: 0.3)
        #expect(limited.ending == .timedOut)
        #expect(stubbornStart.duration(to: .now) < .seconds(Self.childLifetimeSeconds))
    }

    @Test("A stuck spend hook fails the exchange as a timeout inside its deadline, and nothing is sent")
    func stuckHookTimesOut() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = SpendHook(executable: try Self.script(directory, "exec sleep \(Self.childLifetimeSeconds)"))
        let inner = ScriptedHTTPClient(status: 200, body: "{}")
        let recorder = try Self.recorder(inner, directory: directory, hook: hook)
        let request = try Self.generateRequest()
        let started = ContinuousClock.now
        do throws(AnalysisHTTPFailure) {
            _ = try await recorder.send(request, timeoutSeconds: 1, maximumBodyBytes: 1024)
            Issue.record("the exchange was sent")
        } catch {
            #expect(error == .timeout)
        }
        #expect(started.duration(to: .now) < .seconds(Self.childLifetimeSeconds))
        #expect(inner.requests.isEmpty)
    }

    @Test("Time a spend hook takes comes out of the exchange's deadline")
    func hookTimeIsCharged() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = SpendHook(executable: try Self.script(directory, #"sleep 0.6; echo '{"reservation": "r1"}'"#))
        let inner = ScriptedHTTPClient(status: 200, body: "{}")
        let recorder = try Self.recorder(inner, directory: directory, hook: hook)
        let request = try Self.generateRequest()
        // A deadline a stalled runner cannot exhaust: the hook's 0.6 s has
        // to come off it whatever the machine load adds on top.
        let deadline = 300.0
        let started = ContinuousClock.now
        _ = try await recorder.send(request, timeoutSeconds: deadline, maximumBodyBytes: 1024)
        let elapsed = started.duration(to: .now).components
        let spent = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        let timeout = try #require(inner.timeouts.first)
        // At least the hook's own 0.6 s comes off, and never more than the
        // whole send took (the bound holds however slow the machine is).
        #expect(timeout <= deadline - 0.55, "the exchange got \(timeout) s of a \(deadline) s deadline after a 0.6 s hook")
        #expect(timeout >= deadline - spent - 0.01, "the exchange got \(timeout) s after \(spent) s")
    }
}

extension ReplayToolTests {
    /// How long a hook's child runs when nothing stops it. The stop tests
    /// bound the hook by this, not by a guess at scheduling delay: a stop
    /// path that works returns well before it at any machine load, and one
    /// that waits for the child cannot. Five minutes, because a three-core
    /// CI runner once held the cooperative pool for 45 seconds while other
    /// suites ran, which a 30-second lifetime read as waiting for the child.
    static let childLifetimeSeconds = 300

    /// Whether the process `pid` is gone, waiting up to `seconds` for it.
    static func processGone(_ pid: pid_t, within seconds: Double = 60) async -> Bool {
        await eventually(within: seconds) { kill(pid, 0) != 0 && errno == ESRCH }
    }

    static func pid(in file: URL) async -> pid_t? {
        guard await eventually({ (try? String(contentsOf: file, encoding: .utf8))?.isEmpty == false }) else { return nil }
        return (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @Test("A hook whose child keeps stdout open still returns at its limit, and the child is stopped")
    func hookChildHoldingStdout() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "child.pid")
        let hook = SpendHook(executable: try Self.script(directory, """
        sh -c 'echo $$ > "\(pidFile.path(percentEncoded: false))"; exec sleep \(Self.childLifetimeSeconds)' &
        echo '{"reservation": "r1"}'
        """))
        let started = ContinuousClock.now
        let reply = await hook.run(["reserve"], timeoutSeconds: 0.3)
        let elapsed = started.duration(to: .now)
        let child = await Self.pid(in: pidFile)
        defer { if let child { kill(child, SIGKILL) } }
        // A hook that waited for the child's output would return only when
        // the child ends by itself; anything before that is the stop path.
        #expect(elapsed < .seconds(Self.childLifetimeSeconds), "returned after \(elapsed): it waited for the child")
        #expect(reply.ending == .timedOut)
        let gone = await Self.processGone(try #require(child))
        #expect(gone, "the hook's child outlived the hook")
    }

    @Test("A hook whose child ignores SIGTERM has its whole process group killed and reaped")
    func hookChildIgnoringTerm() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "child.pid")
        let hook = SpendHook(executable: try Self.script(directory, """
        sh -c 'trap "" TERM; echo $$ > "\(pidFile.path(percentEncoded: false))"; i=0; while [ $i -lt \(Self.childLifetimeSeconds) ]; do sleep 1; i=$((i + 1)); done' &
        wait
        """))
        let started = ContinuousClock.now
        let reply = await hook.run(["reserve"], timeoutSeconds: 0.3)
        let elapsed = started.duration(to: .now)
        let child = await Self.pid(in: pidFile)
        defer { if let child { kill(child, SIGKILL) } }
        #expect(reply.ending == .timedOut)
        // Without the SIGKILL the hook would wait for the TERM-ignoring
        // child to end by itself.
        #expect(elapsed < .seconds(Self.childLifetimeSeconds), "returned after \(elapsed): the group was not killed")
        let gone = await Self.processGone(try #require(child))
        #expect(gone, "a TERM-ignoring child survived")
    }

    @Test("A hook's output is captured up to a bound")
    func hookOutputIsBounded() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = SpendHook(executable: try Self.script(directory, #"head -c 2000000 /dev/zero | tr '\0' 'x'; echo '{"reservation": "r1"}'"#))
        let reply = await hook.run(["reserve"], timeoutSeconds: 300)
        #expect(reply.status == 0)
        #expect(reply.output == nil)
    }

    /// A spend hook that writes its arguments to `log` and answers each call.
    static func recordingHook(_ directory: URL, log: URL) throws -> SpendHook {
        SpendHook(executable: try Self.script(directory, """
        printf '%s\\n' "$@" >> "\(log.path(percentEncoded: false))"
        case "$1" in
          reserve) echo '{"reservation": "r1"}' ;;
          settle) echo '{"cost_usd": 0.5}' ;;
          *) echo '{}' ;;
        esac
        """))
    }

    @Test("Measured times never fail a record's verification by chance: a key holding nearly every run of four digits")
    func measuredTimesNeverCollide() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try Self.generateRequest()
        // The exchange's fixed numbers stay out of the key, so only a
        // measured time can collide: every other run of four digits is a
        // window of it.
        let fixed = [((request.body?.count ?? 0) + 1) / 2, ProviderTestSupport.openAIEntry().maxOutputTokens, 200, 30, 0]
            .map(String.init)
        let groups = (0..<10_000).map { String(format: "%04d", $0) }.filter { group in !fixed.contains { $0.contains(group) } }
        let key = try #require(AnalysisProviderKey("sk-" + "proj-" + groups.joined(separator: "x")))
        let log = directory.appending(path: "hook-arguments.txt")
        let recorder = try Self.recorder(ScriptedHTTPClient(status: 200, body: #"{"status":"completed","output":[]}"#), directory: directory,
                                         key: key, hook: try Self.recordingHook(directory, log: log))
        _ = try await recorder.send(request, timeoutSeconds: 300, maximumBodyBytes: 4096)
        let exchanges = directory.appending(path: "exchanges")
        let names = try FileManager.default.contentsOfDirectory(atPath: exchanges.path(percentEncoded: false))
        let meta = try String(contentsOf: exchanges.appending(path: try #require(names.first { $0.hasSuffix(".meta.json") })), encoding: .utf8)
        #expect(meta.contains(#""response_recorded":"#) && meta.contains(#""seconds":"#), "\(meta)")
        // The live tool's outcome keeps each send's times the same way.
        let send = AnalysisProviderSendRecord(
            provider: .openai, modelID: "m", feature: .adDetection, purpose: .adWindow(index: 0), sendIndex: 0, status: 200,
            finishReason: .stop, failure: nil, usage: nil, pacedSeconds: 0.1234567891, exchangeSeconds: 7.6543219876
        )
        let outcome = try LiveRun.write(.object([JSONMember("sends", .array([LiveRun.sendJSON(send)]))]),
                                        to: directory.appending(path: "outcome.json"), key: key)
        #expect(outcome["sends"]?.arrayValue?.first?["paced_s"] == .double(0.123), "\(outcome)")
        #expect(outcome["sends"]?.arrayValue?.first?["exchange_s"] == .double(7.654), "\(outcome)")
    }

    @Test("A usage number that matches a key fragment suppresses the recording, and the ledger still settles from the counts")
    func numericCollisionStillSettles() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyText = "sk-" + "proj-" + String(repeating: "Hx3", count: 14) + "1234"
        let key = try #require(AnalysisProviderKey(keyText))
        let body = #"{"id":"resp_1","object":"response","status":"completed","output":[],"usage":{"input_tokens":1234,"output_tokens":51234,"output_tokens_details":{"reasoning_tokens":12345},"input_tokens_details":{"cached_tokens":7},"total_tokens":52468}}"#
        let log = directory.appending(path: "hook-arguments.txt")
        let recorder = try Self.recorder(ScriptedHTTPClient(status: 200, body: body), directory: directory, key: key,
                                         hook: try Self.recordingHook(directory, log: log))
        _ = try await recorder.send(try Self.generateRequest(), timeoutSeconds: 300, maximumBodyBytes: 4096)
        let exchanges = directory.appending(path: "exchanges")
        let names = try FileManager.default.contentsOfDirectory(atPath: exchanges.path(percentEncoded: false))
        let response = try String(contentsOf: exchanges.appending(path: try #require(names.first { $0.hasSuffix(".response.json") })), encoding: .utf8)
        #expect(FragmentOracle.isPlaceholder(response), "\(response)")
        #expect(!response.contains("1234"))
        let meta = try String(contentsOf: exchanges.appending(path: try #require(names.first { $0.hasSuffix(".meta.json") })), encoding: .utf8)
        #expect(meta.contains(#""response_recorded":false"#), "\(meta)")
        let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let settle = try #require(arguments.firstIndex(of: "settle"), "\(arguments)")
        let usage = try #require(arguments.firstIndex(of: "--usage").map { arguments[$0 + 1] })
        #expect(settle >= 0)
        #expect(try JSONParser.parse(usage) == JSONParser.parse(#"{"input":1234,"cached":7,"write":0,"output":51234,"reasoning":12345}"#))
        #expect(!arguments.contains("--response"))
    }

    @Test("Every recorder write path is verified: request, response, meta and the live tool's outcome files")
    func everyWritePathVerified() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ProviderTestKeys.openAI
        let fragments = FragmentOracle.fragments([ProviderTestKeys.openAIText])
        // The key planted in the request body, the response and the hook's
        // reservation id: every file is redacted or replaced, none leaks.
        let planted = String(ProviderTestKeys.openAIText.dropFirst(10))
        let log = directory.appending(path: "hook-arguments.txt")
        let hookDirectory = directory.appending(path: "hook")
        let hook = SpendHook(executable: try Self.script(hookDirectory, """
        case "$1" in
          reserve) echo '{"reservation": "\(planted)"}' ;;
          *) echo '{}' ;;
        esac
        printf '%s\\n' "$1" >> "\(log.path(percentEncoded: false))"
        """))
        let recorder = try Self.recorder(ScriptedHTTPClient(status: 400, body: #"{"error":{"message":"bad \#(planted)"}}"#),
                                         directory: directory, key: key, hook: hook)
        var request = try Self.generateRequest()
        request.body = Data(#"{"input":"\#(planted)","n":1}"#.utf8)
        _ = try? await recorder.send(request, timeoutSeconds: 300, maximumBodyBytes: 4096)
        let texts = try Self.recordedTexts(directory)
        #expect(texts.count == 3)
        for text in texts {
            #expect(FragmentOracle.leak(inArtifact: text, fragments: fragments) == nil, "\(text)")
        }
        let outcome = try LiveRun.write(.object([JSONMember("response", .string("echo \(planted)")), JSONMember("n", .integer(2))]),
                                        to: directory.appending(path: "outcome.json"), key: key)
        let written = try String(contentsOf: directory.appending(path: "outcome.json"), encoding: .utf8)
        #expect(FragmentOracle.leak(inArtifact: written, fragments: fragments) == nil, "\(written)")
        #expect(outcome["n"] == .integer(2))
        // A request body that is not JSON is never written as text.
        var opaque = try Self.generateRequest()
        opaque.body = Data("not json \(planted)".utf8)
        _ = try? await recorder.send(opaque, timeoutSeconds: 300, maximumBodyBytes: 4096)
        for text in try Self.recordedTexts(directory) {
            #expect(!text.contains("not json"), "\(text)")
        }
    }

    @Test("No masking style of an echoed key reaches the recording: the message is never kept, the closed fields are")
    func recorderRedactsEveryMaskStyle() async throws {
        for mask in ["***", "…", "●●●●", "...", "*", #"\u2022\u2022\u2022"#] {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = try #require(AnalysisProviderKey(RedactionTests.maskedKey))
            let echo = RedactionTests.maskedEcho.replacing("************************************", with: mask)
            let recorder = try Self.recorder(ScriptedHTTPClient(status: 401, body: echo), directory: directory, key: key)
            _ = try? await recorder.send(try Self.generateRequest(), timeoutSeconds: 300, maximumBodyBytes: 4096)
            let texts = try Self.recordedTexts(directory)
            for text in texts {
                #expect(!text.contains("Incorrect API key"), "\(mask): \(text)")
                #expect(!text.contains("sk-proj-"), "\(mask): \(text)")
                #expect(!text.contains(RedactionTests.maskedKeySuffix), "\(mask): \(text)")
                #expect((try? JSONParser.parse(text)) != nil, "\(mask): not JSON")
            }
            #expect(texts.contains { $0.contains(#""listener":"invalid_key""#) && $0.contains(#""error_code":"invalid_api_key""#) }, "\(mask): \(texts)")
        }
    }

    @Test("A stopped hook ends on SIGTERM, without waiting for SIGKILL")
    func hookEndsOnTerm() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A child that could end by itself before a starved timeout fires
        // would make the exit, not the signal, the ending.
        let hook = SpendHook(executable: try Self.script(directory, "exec sleep \(Self.childLifetimeSeconds)"))
        let reply = await hook.run(["reserve"], timeoutSeconds: 0.2)
        #expect(reply.ending == .timedOut)
        #expect(reply.signal == SIGTERM, "ended by signal \(reply.signal.map(String.init) ?? "none"), not SIGTERM")
    }

    @Test("Huge or non-finite time limits neither trap nor wait forever")
    func hugeLimits() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = SpendHook(executable: try Self.script(directory, #"echo '{"reservation": "r1"}'"#))
        #expect(await hook.run(["reserve"], timeoutSeconds: 1e300).status == 0)
        let recorder = try Self.recorder(ScriptedHTTPClient(status: 200, body: "{}"), directory: directory, hook: hook)
        let response = try await recorder.send(try Self.generateRequest(), timeoutSeconds: 1e300, maximumBodyBytes: 1024)
        #expect(response.status == 200)
    }
}
