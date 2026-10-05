import CryptoKit
import DeviceCheck
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// Recovery-contract checks: the additive reference fields decode with their
/// documented defaults, the fault-injecting fake tells a request that never
/// left apart from one the server accepted and enforces the Worker's state
/// rules, every fixture in the catalog has an owner, and the diagnostic
/// vocabulary cannot carry private content.
@MainActor
@Suite("Remote job recovery contracts")
struct RemoteJobRecoveryContractTests {
    private typealias Traffic = RemoteJobFaultInjectingAPI.TrafficEntry

    // MARK: Reference decoding defaults

    @Test("An old reference without a job ID decodes as prepared with local defaults")
    func oldReferenceWithoutJobIDDecodesAsPrepared() throws {
        let json = #"{"episodeID":"ep-old","clientRequestID":"req-old","createdAt":780000000}"#
        let reference = try JSONDecoder().decode(RemoteTranscriptionJobReference.self, from: Data(json.utf8))

        #expect(reference.jobID == nil)
        #expect(reference.resolvedPurpose == .transcription)
        #expect(reference.createState == .prepared)
        #expect(reference.lastExit == nil)
        #expect(reference.userCancelRequestedAt == nil)
        #expect(reference.completionDeliveryOwner == .local)
    }

    @Test("An old reference with a job ID decodes as attached")
    func oldReferenceWithJobIDDecodesAsAttached() throws {
        let json = #"""
        {"episodeID":"ep-old","clientRequestID":"req-old","jobID":"job-old","createdAt":780000000,"purpose":"adDetection"}
        """#
        let reference = try JSONDecoder().decode(RemoteTranscriptionJobReference.self, from: Data(json.utf8))

        #expect(reference.jobID == "job-old")
        #expect(reference.resolvedPurpose == .adDetection)
        #expect(reference.createState == .attached)
        #expect(reference.completionDeliveryOwner == .local)
    }

    @Test("The recovery fields round-trip and the memberwise default infers create state from the job ID")
    func newFieldsRoundTrip() throws {
        let cancelledAt = Date(timeIntervalSinceReferenceDate: 790_000_000)
        let original = RemoteTranscriptionJobReference(
            episodeID: "ep-new",
            clientRequestID: "req-new",
            jobID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            purpose: .transcription,
            createState: .createAttempted,
            lastExit: .connectionLost,
            userCancelRequestedAt: cancelledAt,
            completionDeliveryOwner: .remote
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteTranscriptionJobReference.self, from: data)

        #expect(decoded == original)
        #expect(decoded.createState == .createAttempted)
        #expect(decoded.lastExit == .connectionLost)
        #expect(decoded.userCancelRequestedAt == cancelledAt)
        #expect(decoded.completionDeliveryOwner == .remote)

        let inferredAttached = RemoteTranscriptionJobReference(
            episodeID: "ep", clientRequestID: "req", jobID: "job", createdAt: .now, purpose: nil
        )
        let inferredPrepared = RemoteTranscriptionJobReference(
            episodeID: "ep", clientRequestID: "req", jobID: nil, createdAt: .now, purpose: nil
        )
        #expect(inferredAttached.createState == .attached)
        #expect(inferredPrepared.createState == .prepared)
    }

    @Test("The recovery window is seven days from creation")
    func recoveryWindowIsSevenDays() {
        let createdAt = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let reference = RemoteTranscriptionJobReference(
            episodeID: "ep", clientRequestID: "req", jobID: nil, createdAt: createdAt, purpose: nil
        )
        #expect(RemoteTranscriptionJobReference.recoveryWindow == 7 * 24 * 60 * 60)
        #expect(reference.isWithinRecoveryWindow(asOf: createdAt.addingTimeInterval(6 * 24 * 60 * 60)))
        #expect(!reference.isWithinRecoveryWindow(asOf: createdAt.addingTimeInterval(7 * 24 * 60 * 60)))
    }

    @Test("The store mints prepared references, attach marks them attached, exits record, and old persisted data still loads")
    func storeMintsPreparedAndLoadsLegacyData() throws {
        let suiteName = "remote-recovery-contracts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = #"[{"episodeID":"ep-legacy","clientRequestID":"req-legacy","jobID":"job-legacy","createdAt":780000000}]"#
        defaults.set(Data(legacy.utf8), forKey: "remoteTranscription.jobReferences")
        let store = RemoteTranscriptionJobStore(defaults: defaults)

        let legacyReference = try #require(store.references().first)
        #expect(legacyReference.clientRequestID == "req-legacy")
        #expect(legacyReference.createState == .attached)
        #expect(legacyReference.completionDeliveryOwner == .local)

        let minted = store.reference(for: "ep-fresh", purpose: .adDetection)
        #expect(minted.createState == .prepared)
        #expect(minted.jobID == nil)
        #expect(store.reference(for: "ep-fresh", purpose: .adDetection).clientRequestID == minted.clientRequestID)

        store.attachJob(id: "job-fresh", episodeID: "ep-fresh", purpose: .adDetection)
        store.recordExit(.parked, episodeID: "ep-fresh", purpose: .adDetection)
        let attached = try #require(store.references().first { $0.episodeID == "ep-fresh" })
        #expect(attached.jobID == "job-fresh")
        #expect(attached.createState == .attached)
        #expect(attached.lastExit == .parked)
        #expect(attached.clientRequestID == minted.clientRequestID)
        // An exit never mints a reference; old rows survive the rewrite.
        store.recordExit(.connectionLost, episodeID: "ep-never", purpose: .transcription)
        #expect(!store.references().contains { $0.episodeID == "ep-never" })
        #expect(store.references().contains { $0.episodeID == "ep-legacy" })
    }

    // MARK: Fake API fault points

    @Test("A create that never leaves the process writes no server mapping")
    func createThatNeverLeavesTouchesNoServerState() async throws {
        let api = RemoteJobRecoveryFixture.createNeverLeaves.makeAPI()

        await #expect(throws: URLError.self) {
            _ = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        }

        #expect(api.serverJobID(forClientRequestID: "req-1") == nil)
        #expect(api.mintedJobIDs.isEmpty)
        #expect(api.createCalls == [
            Traffic(leg: .create, clientRequestID: "req-1", jobID: nil, reachedServer: false, responseDelivered: false),
        ])
        #expect(api.callSequence.isEmpty)
        #expect(api.cancelCalls.isEmpty)
    }

    @Test("An accepted create with a lost response is discoverable by the same client request ID")
    func acceptedCreateWithLostResponseIsDiscoverable() async throws {
        let api = RemoteJobRecoveryFixture.createAcceptedResponseLost.makeAPI()

        await #expect(throws: URLError.self) {
            _ = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        }
        #expect(api.serverJobID(forClientRequestID: "req-1") == "job-fake-1")
        #expect(api.createCalls == [
            Traffic(leg: .create, clientRequestID: "req-1", jobID: "job-fake-1", reachedServer: true, responseDelivered: false),
        ])

        let repeated = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        #expect(repeated.job.jobID == "job-fake-1")
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.callSequence == [.create, .create])
    }

    @Test("A different client request ID mints a second job, which is the double-pay the contract forbids")
    func differentClientIDMintsSecondJob() async throws {
        let api = RemoteJobRecoveryFixture.createAcceptedResponseLost.makeAPI()
        _ = try? await api.createJob(Self.createRequest(clientRequestID: "req-1"))

        let second = try await api.createJob(Self.createRequest(clientRequestID: "req-2"))

        #expect(second.job.jobID == "job-fake-2")
        #expect(api.mintedJobIDs == ["job-fake-1", "job-fake-2"])
    }

    @Test("A delayed create waits for its gate, not for time")
    func delayedCreateWaitsForGate() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let api = RemoteJobRecoveryFixture.createDelayedThenUserCancels.makeAPI(gate: gate)
        let request = Self.createRequest(clientRequestID: "req-1")

        let inFlight = Task { try await api.createJob(request) }
        await Task.yield()
        #expect(api.serverJobID(forClientRequestID: "req-1") == nil)
        #expect(!gate.isReleased)

        gate.release()
        let response = try await inFlight.value
        #expect(response.job.jobID == "job-fake-1")
        #expect(api.createCalls.last?.responseDelivered == true)

        // A create arriving after the gate opened is not held.
        let later = try await api.createJob(request)
        #expect(later.job.jobID == "job-fake-1")
    }

    @Test("A cancel whose response is lost still cancels the server job")
    func lostCancelResponseStillCancelsServerJob() async throws {
        let api = RemoteJobRecoveryFixture.cancelResponseLost.makeAPI()
        let created = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))

        await #expect(throws: URLError.self) {
            _ = try await api.cancel(jobID: created.job.jobID)
        }

        #expect(api.serverState(of: created.job.jobID) == .cancelled)
        #expect(api.cancelCalls == [
            Traffic(leg: .cancel, clientRequestID: nil, jobID: created.job.jobID, reachedServer: true, responseDelivered: false),
        ])
        // Server truth outranks the scripted transcribing state afterwards.
        let poll = try await api.poll(jobID: created.job.jobID)
        #expect(poll.job.state == .cancelled)
    }

    @Test("A local leg failure never reaches the server and keeps its error type")
    func localLegFailureNeverReachesServer() async throws {
        let api = RemoteJobRecoveryFixture.localLegFailure.makeAPI()
        let created = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))

        await #expect(throws: AppAttestKeychainError.self) {
            _ = try await api.poll(jobID: created.job.jobID)
        }
        // Persistent faults keep failing until the caller gives up.
        await #expect(throws: AppAttestKeychainError.self) {
            _ = try await api.poll(jobID: created.job.jobID)
        }

        #expect(api.pollCalls.count == 2)
        #expect(api.pollCalls.allSatisfy { !$0.reachedServer })
        #expect(api.serverState(of: created.job.jobID) == .created)
    }

    @Test("A landed create error leaves no mapping, so the same client request ID may be retried")
    func landedCreateErrorLeavesNoMapping() async throws {
        let api = RemoteJobFaultInjectingAPI()
        api.inject(.landed(RemoteTranscriptionHTTPError(statusCode: 429, code: "rate_limited", detail: nil)), at: .create)

        await #expect(throws: RemoteTranscriptionHTTPError.self) {
            _ = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        }
        #expect(api.serverJobID(forClientRequestID: "req-1") == nil)
        #expect(api.createCalls.first == Traffic(
            leg: .create, clientRequestID: "req-1", jobID: nil, reachedServer: true, responseDelivered: true
        ))

        let retried = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        #expect(retried.job.jobID == "job-fake-1")
        #expect(api.mintedJobIDs == ["job-fake-1"])
    }

    // MARK: Fake API server state rules

    @Test("Result and ack are refused until the job is result_ready, and a delivered result moves it to delivered")
    func resultAndAckFollowServerStateRules() async throws {
        let api = RemoteJobFaultInjectingAPI(
            pollScript: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .resultReady),
            ],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(
                schemaVersion: 1,
                result: Self.result(identity: Self.identity(for: Data("x".utf8)), durationSeconds: 1)
            )
        )
        let created = try await api.createJob(Self.createRequest(clientRequestID: "req-1"))
        let jobID = created.job.jobID

        await #expect(throws: RemoteTranscriptionHTTPError.self) { _ = try await api.result(jobID: jobID) }
        await #expect(throws: RemoteTranscriptionHTTPError.self) { _ = try await api.ack(jobID: jobID, normalizedTranscriptSHA256: nil) }
        #expect(api.serverState(of: jobID) == .created)

        _ = try await api.poll(jobID: jobID)
        #expect(api.serverState(of: jobID) == .transcribing)
        await #expect(throws: RemoteTranscriptionHTTPError.self) { _ = try await api.result(jobID: jobID) }

        let ready = try await api.poll(jobID: jobID)
        #expect(ready.job.state == .resultReady)
        _ = try await api.result(jobID: jobID)
        #expect(api.serverState(of: jobID) == .delivered)
        // Delivered is server truth: the script's last state no longer repeats.
        #expect(try await api.poll(jobID: jobID).job.state == .delivered)

        let acked = try await api.ack(jobID: jobID, normalizedTranscriptSHA256: "aa")
        #expect(acked.job.state == .acknowledged)
        #expect(api.callSequence == [.create, .result, .ack, .poll, .result, .poll, .result, .poll, .ack])
        #expect(api.ackHashes == ["aa"])
    }

    @Test("Ack on an acknowledged job and cancel on a terminal job are idempotent status reads")
    func terminalMutationsAreIdempotent() async throws {
        let api = RemoteJobRecoveryFixture.deathAfterAck.makeAPI()
        api.seedServerJob(clientRequestID: "req-prior", jobID: "job-prior", state: .acknowledged)

        let repeatedAck = try await api.ack(jobID: "job-prior", normalizedTranscriptSHA256: "aa")
        let cancelled = try await api.cancel(jobID: "job-prior")
        let poll = try await api.poll(jobID: "job-prior")

        #expect(repeatedAck.job.state == .acknowledged)
        #expect(cancelled.job.state == .acknowledged)
        #expect(poll.job.state == .acknowledged)
        #expect(api.ackHashes == ["aa"])
        #expect(api.cancelCalls.count == 1)
        #expect(api.serverState(of: "job-prior") == .acknowledged)
    }

    @Test("Unknown jobs answer 404 on every job route")
    func unknownJobIsNotFound() async {
        let api = RemoteJobFaultInjectingAPI()
        for call: () async throws -> Void in [
            { _ = try await api.poll(jobID: "job-missing") },
            { _ = try await api.result(jobID: "job-missing") },
            { _ = try await api.ack(jobID: "job-missing", normalizedTranscriptSHA256: nil) },
            { _ = try await api.cancel(jobID: "job-missing") },
        ] {
            await #expect(throws: RemoteTranscriptionHTTPError.self) { try await call() }
        }
        #expect(api.traffic.allSatisfy { $0.reachedServer && $0.jobID == "job-missing" })
    }

    @Test("A seeded server job answers a relaunch create with the same job ID")
    func seededServerJobAttachesOnRelaunchCreate() async throws {
        let api = RemoteJobRecoveryFixture.deathAfterAck.makeAPI()
        api.seedServerJob(clientRequestID: "req-prior", jobID: "job-prior", state: .acknowledged)

        let attached = try await api.createJob(Self.createRequest(clientRequestID: "req-prior"))
        let poll = try await api.poll(jobID: "job-prior")

        #expect(attached.job.jobID == "job-prior")
        #expect(attached.job.state == .acknowledged)
        #expect(poll.job.state == .acknowledged)
        #expect(api.mintedJobIDs == ["job-prior"])
    }

    // MARK: Fixture catalog

    @Test("Every fixture builds a fake, names an owning pass and a required assertion")
    func everyFixtureIsOwnedAndBuildable() {
        let ids = RemoteJobRecoveryFixture.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 12)
        for fixture in RemoteJobRecoveryFixture.allCases {
            #expect(["01", "03", "05"].contains(fixture.owningPass), "\(fixture) owner")
            #expect(!fixture.requiredAssertion.isEmpty, "\(fixture) assertion")
            let api = fixture.makeAPI()
            #expect(api.mintedJobIDs.isEmpty, "\(fixture) starts with no server job")
        }
    }

    @Test("The parked cloud fixtures seed a parked reference, a pending cloud record and a running server job")
    func parkedFixturesSeedPersistedState() async throws {
        for fixture in [RemoteJobRecoveryFixture.cloudParked, .parkedCloudUserCancel] {
            let environment = try await Self.makeEnvironment(episodeID: "ep-parked-\(fixture.rawValue)")
            let api = fixture.makeAPI()

            let seed = try #require(try fixture.seedPersistedState(
                store: environment.store,
                api: api,
                modelContext: environment.context,
                episode: environment.episode
            ))

            #expect(seed.reference.resolvedPurpose == .adDetection)
            #expect(seed.reference.createState == .attached)
            #expect(seed.reference.jobID == RemoteJobRecoveryFixture.seededJobID)
            #expect(seed.reference.lastExit == .parked)
            #expect(seed.reference.userCancelRequestedAt == nil)
            let records = try environment.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
            #expect(records.map(\.episodeID) == [environment.episode.episodeID])
            #expect(records.first?.modeRawValue == AdDetectionMode.cloud.rawValue)
            #expect(records.first?.remoteParkReasonRawValue == RemoteTranscriptionJobExit.parked.rawValue)
            #expect(api.serverState(of: seed.jobID) == .transcribing)

            // Resume re-attaches by the same client request ID without a
            // second job and without any cancel.
            let attached = try await api.createJob(Self.createRequest(clientRequestID: seed.reference.clientRequestID))
            #expect(attached.job.jobID == seed.jobID)
            #expect(api.mintedJobIDs == [seed.jobID])
            #expect(api.cancelCalls.isEmpty)
            #expect(try await api.poll(jobID: seed.jobID).job.state == .transcribing)
        }
    }

    @Test("The parked user-cancel fixture takes exactly one cancel and never resumes")
    func parkedUserCancelFixtureTakesOneCancel() async throws {
        let environment = try await Self.makeEnvironment(episodeID: "ep-parked-cancel")
        let fixture = RemoteJobRecoveryFixture.parkedCloudUserCancel
        let api = fixture.makeAPI()
        let seed = try #require(try fixture.seedPersistedState(
            store: environment.store, api: api, modelContext: environment.context, episode: environment.episode
        ))

        let cancelled = try await api.cancel(jobID: seed.jobID)
        let again = try await api.cancel(jobID: seed.jobID)
        let reattach = try await api.createJob(Self.createRequest(clientRequestID: seed.reference.clientRequestID))

        #expect(cancelled.job.state == .cancelled)
        #expect(again.job.state == .cancelled)
        #expect(reattach.job.state == .cancelled)
        #expect(api.cancelCalls.count == 2)
        #expect(api.mintedJobIDs == [seed.jobID])
    }

    // MARK: Runner compatibility

    @Test("The current runner completes a fault-free run against the fake in the contract's call order")
    func currentRunnerCompletesAgainstTheFake() async throws {
        let environment = try await Self.makeEnvironment(episodeID: "ep-contract-happy")
        let result = Self.result(identity: environment.identity, durationSeconds: 120)
        let api = RemoteJobRecoveryFixture.ownerBeforeClear.makeAPI(
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result)
        )
        let runner = RemoteTranscriptionJobRunner(
            api: api,
            downloads: environment.downloads,
            transcriptions: environment.transcriptions,
            store: environment.store,
            transportRetryDelays: []
        )

        let outcome = try await runner.run(
            episode: environment.episode,
            enclosureURL: environment.episode.audioURL!,
            purpose: .transcription,
            modelContext: environment.context,
            onEvent: { _ in }
        )

        #expect(outcome.jobID == "job-fake-1")
        #expect(api.callSequence == [.bootstrap, .create, .source, .poll, .result, .ack, .bootstrap])
        #expect(api.traffic.allSatisfy { $0.reachedServer && $0.responseDelivered })
        #expect(api.createCalls.first?.clientRequestID != nil)
        #expect(api.reportedIdentities.map(\.sha256) == [environment.identity.sha256])
        #expect(api.ackHashes == [result.provenance.normalizedTranscriptSHA256])
        #expect(api.serverState(of: "job-fake-1") == .acknowledged)
        #expect(environment.store.references().isEmpty)
        #expect(environment.transcriptions.document(for: "ep-contract-happy")?.remoteJobProvenanceToken == "job-fake-1")
    }

    // MARK: Diagnostics vocabulary

    @Test("Encoded diagnostic events stay within the field allow-list")
    func encodedEventKeysStayWithinAllowList() throws {
        let event = RemoteJobDiagnosticEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 780_000_000),
            component: .runner,
            kind: .legFailed,
            episodeID: "ep-hash",
            jobID: "job-1",
            clientRequestID: "req-1",
            purpose: .adDetection,
            leg: .poll,
            attempt: 2,
            elapsedMilliseconds: 1_234,
            httpStatus: 503,
            serverState: .transcribing,
            error: RemoteJobDiagnosticError(classifying: URLError(.notConnectedToInternet)),
            disposition: .retained
        )
        let data = try JSONEncoder().encode(event)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == RemoteJobDiagnosticEvent.allowedFieldNames)
        #expect(object["serverState"] as? String == "transcribing")
        let errorObject = try #require(object["error"] as? [String: Any])
        #expect(Set(errorObject.keys).isSubset(of: RemoteJobDiagnosticError.allowedFieldNames))
        #expect(try JSONDecoder().decode(RemoteJobDiagnosticEvent.self, from: data) == event)
        #expect(RemoteJobDiagnosticEvent.Kind.allCases.count == 28)
    }

    @Test("Unknown server states and wire codes encode as unknown, never as the server's raw string")
    func unknownVocabularyValuesEncodeAsUnknown() throws {
        let event = RemoteJobDiagnosticEvent(
            component: .runner,
            kind: .pollObserved,
            serverState: .unknown("Secret Title https://private.example"),
            error: RemoteJobDiagnosticError(
                domain: .http, code: 500, wireCode: .unknown("Secret Title https://private.example")
            )
        )
        let text = try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))

        #expect(!text.contains("Secret Title"))
        #expect(!text.contains("private.example"))
        #expect(text.contains(#""serverState":"unknown""#))
        #expect(text.contains(#""wireCode":"unknown""#))
    }

    @Test("The error classifier keeps only a domain, code and closed machine codes")
    func classifierKeepsDomainAndCodeOnly() {
        #expect(
            RemoteJobDiagnosticError(classifying: URLError(.notConnectedToInternet))
                == RemoteJobDiagnosticError(domain: .transport, code: -1009, frameworkDomain: .urlError)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: RemoteTranscriptionHTTPError(statusCode: 503, code: "rate_limited", detail: "x"))
                == RemoteJobDiagnosticError(domain: .http, code: 503, wireCode: .rateLimited)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: RemoteTranscriptionHTTPError(statusCode: 503, code: "made_up_code", detail: nil))
                == RemoteJobDiagnosticError(domain: .http, code: 503)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: RemoteTranscriptionHTTPError(statusCode: -1, code: "invalid_response", detail: nil))
                == RemoteJobDiagnosticError(domain: .transport, code: -1, localCode: .invalidResponse)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: AppAttestKeychainError(status: -25300))
                == RemoteJobDiagnosticError(domain: .keychain, code: -25300)
        )
        let deviceCheckError = NSError(domain: DCError.errorDomain, code: DCError.Code.serverUnavailable.rawValue)
        #expect(
            RemoteJobDiagnosticError(classifying: deviceCheckError)
                == RemoteJobDiagnosticError(domain: .deviceCheck, code: DCError.Code.serverUnavailable.rawValue, frameworkDomain: .deviceCheck)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: RemoteTranscriptionJobRunError.serverRejected(.insufficientCredits))
                == RemoteJobDiagnosticError(domain: .runner, wireCode: .insufficientCredits)
        )
        #expect(
            RemoteJobDiagnosticError(classifying: RemoteTranscriptionJobRunError.serviceUnavailable)
                == RemoteJobDiagnosticError(domain: .runner, localCode: .serviceUnavailable)
        )
        #expect(RemoteJobDiagnosticError(classifying: CancellationError()) == RemoteJobDiagnosticError(domain: .cancellation))
        let decodeFailure = DecodingError.keyNotFound(
            AnyKey(stringValue: "jobID"),
            DecodingError.Context(codingPath: [], debugDescription: "Episode Secret Title")
        )
        #expect(RemoteJobDiagnosticError(classifying: decodeFailure) == RemoteJobDiagnosticError(domain: .decode, localCode: .keyNotFound))
    }

    @Test("A classified error never encodes its description or an unknown domain string")
    func classifiedErrorNeverEncodesDescription() throws {
        let downloadError = DownloadStore.CompletedDownloadError.notCompleted(
            state: .failed,
            errorMessage: "https://private.example/secret-episode.mp3"
        )
        let leaky = LeakyDescriptionError()

        for error in [RemoteJobDiagnosticError(classifying: downloadError), RemoteJobDiagnosticError(classifying: leaky)] {
            let text = try #require(String(data: JSONEncoder().encode(error), encoding: .utf8))
            #expect(!text.contains("private.example"))
            #expect(!text.contains("Secret Title"))
            #expect(!text.contains("LeakyDescriptionError"))
        }
        #expect(RemoteJobDiagnosticError(classifying: downloadError).localCode == .notCompleted)
        let classifiedLeak = RemoteJobDiagnosticError(classifying: leaky)
        #expect(classifiedLeak.domain == .other)
        #expect(classifiedLeak.frameworkDomain == .other)
    }

    // MARK: Helpers

    private struct LeakyDescriptionError: LocalizedError {
        var errorDescription: String? { "Episode Secret Title at https://private.example/x" }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Environment {
        var store: RemoteTranscriptionJobStore
        var transcriptions: EpisodeTranscriptionStore
        var downloads: DownloadStore
        var context: ModelContext
        var episode: EpisodeListItemSnapshot
        var identity: OpenCastRemoteTranscriptionSourceIdentity
    }

    private static func createRequest(clientRequestID: String) -> OpenCastRemoteTranscriptionJobCreateRequest {
        OpenCastRemoteTranscriptionJobCreateRequest(
            clientRequestID: clientRequestID,
            episodeID: "ep-contract",
            enclosureURL: "https://example.com/ep-contract.mp3"
        )
    }

    private static func identity(for data: Data) -> OpenCastRemoteTranscriptionSourceIdentity {
        OpenCastRemoteTranscriptionSourceIdentity(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count),
            durationSeconds: 120
        )
    }

    private static func makeEnvironment(episodeID: String) async throws -> Environment {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: episodeID,
            duration: 120,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: "https://example.com/art.jpg",
            guid: episodeID
        )

        let sourceURL = URL(string: episode.audioURL!)!
        let relativePath = downloadFileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
        let fileURL = downloadFileStore.fileURL(relativePath: relativePath)
        let data = Data("remote audio bytes \(episodeID)".utf8)
        try downloadFileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
        let identity = identity(for: data)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        record.sourceFileSHA256 = identity.sha256
        record.duration = 120
        context.insert(record)
        try context.save()
        await downloads.load(modelContext: context)

        let suiteName = "remote-recovery-contracts-\(episodeID)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Environment(
            store: RemoteTranscriptionJobStore(defaults: defaults),
            transcriptions: transcriptions,
            downloads: downloads,
            context: context,
            episode: episode,
            identity: identity
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A result whose words and normalized hash are self-consistent, so it
    /// passes mapper validation against the given identity.
    private static func result(
        identity: OpenCastRemoteTranscriptionSourceIdentity,
        durationSeconds: Double
    ) -> OpenCastRemoteTranscriptionResult {
        let words = [
            OpenCastRemoteTranscriptWord(start: 0.0, end: 0.6, text: "Hello"),
            OpenCastRemoteTranscriptWord(start: 0.6, end: 1.1, text: "remote"),
            OpenCastRemoteTranscriptWord(start: 1.1, end: 1.7, text: "transcript."),
        ]
        let normalized = OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(
            words.map(\.text).joined(separator: " ")
        )
        return OpenCastRemoteTranscriptionResult(
            schemaVersion: 1,
            sourceIdentity: identity,
            languageCode: "en",
            durationSeconds: durationSeconds,
            text: "Hello remote transcript.",
            segments: [
                OpenCastRemoteTranscriptSegment(id: 0, start: 0.0, end: 1.7, text: "Hello remote transcript.", words: words),
            ],
            provenance: OpenCastRemoteTranscriptionModelProvenance(
                provider: "cloudflare-workers-ai",
                modelIdentifier: "@cf/openai/whisper-large-v3-turbo",
                modelRevision: nil,
                servingContractVersion: "1",
                requestSettingsSHA256: String(repeating: "a", count: 64),
                chunkManifestSHA256: String(repeating: "b", count: 64),
                normalizedTranscriptSHA256: normalized,
                pipelineVersion: "stitch-v3"
            ),
            warnings: []
        )
    }
}
