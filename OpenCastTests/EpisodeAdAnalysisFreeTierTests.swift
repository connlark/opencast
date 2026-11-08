import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Synchronization
import Testing
@testable import OpenCast

/// A Google key on the free tier, through the store: the check before a run
/// and after a failed one, the handover to the trial service, how each run
/// ends, and recovery. The route always follows the answer given in the run;
/// the stored state only decides whether to ask.
@MainActor
@Suite("Episode ad analysis free tier")
struct EpisodeAdAnalysisFreeTierTests {
    private static let overloaded = ScriptedAdAnswer.failure(.retryable(status: 503, retryAfterSeconds: 0), status: 503, listener: .overloaded)
    private static let namedFreeTier = ScriptedAdAnswer.freeTierFailure(.quotaExhausted, listener: .billingOrQuota)

    /// One store over a scripted environment, in a directory of its own.
    @MainActor
    private final class Fixture {
        let context: ModelContext
        let directory: URL
        let environment: ScriptedAdAnalysisRunEnvironment
        let store: EpisodeAdAnalysisStore
        let transcript: EpisodeTranscriptDocument
        var episodeID: String { transcript.episodeID }

        init(
            episodeID: String = "free-tier-episode",
            segmentCount: Int = 2,
            environment: ScriptedAdAnalysisRunEnvironment = ScriptedAdAnalysisRunEnvironment()
        ) throws {
            context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
            directory = FileManager.default.temporaryDirectory
                .appending(path: "OpenCastFreeTierTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.environment = environment
            store = Self.makeStore(directory: directory, environment: environment)
            transcript = transcriptDocument(episodeID: episodeID, segmentCount: segmentCount)
        }

        static func makeStore(directory: URL, environment: ScriptedAdAnalysisRunEnvironment) -> EpisodeAdAnalysisStore {
            EpisodeAdAnalysisStore(
                client: UnpolledAdAnalysisClient(),
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
                runEnvironment: environment,
                preparationGate: {}
            )
        }

        func start(_ document: EpisodeTranscriptDocument? = nil) {
            store.startAnalysis(transcript: document ?? transcript, modelContext: context)
        }

        /// Starts a run and waits for it to end.
        func run(_ document: EpisodeTranscriptDocument? = nil) async {
            start(document)
            #expect(await waitUntil { !self.store.hasActiveJob })
        }

        /// What a launch's resume reads the transcript from.
        func writeTranscript() throws {
            let document = transcript
            let fileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
            let fingerprint = fileStore.fingerprint(
                sourceFileSHA256: document.sourceFileSHA256,
                modelIdentifier: document.modelIdentifier,
                modelVersion: document.modelVersion,
                modelTreeSHA256: document.modelTreeSHA256
            )
            let relativePath = fileStore.relativePath(episodeID: document.episodeID, fingerprint: fingerprint)
            try fileStore.write(document, relativePath: relativePath)
            context.insert(EpisodeTranscriptRecord(
                episodeID: document.episodeID,
                podcastID: document.podcastID,
                sourceAudioURL: document.sourceAudioURL,
                sourceFileByteCount: document.sourceFileByteCount,
                sourceFileSHA256: document.sourceFileSHA256,
                modelIdentifier: document.modelIdentifier,
                modelVersion: document.modelVersion,
                modelTreeSHA256: document.modelTreeSHA256,
                languageCode: document.languageCode,
                state: .completed,
                audioDuration: document.audioDuration,
                completedDuration: document.audioDuration,
                checkpointCount: document.checkpoints.count,
                transcriptRelativePath: relativePath,
                createdAt: document.createdAt,
                updatedAt: document.updatedAt
            ))
            try context.save()
        }

        var record: EpisodeAdAnalysisRecord? { store.record(for: episodeID) }
        var runs: [AnalysisRunRecord] { environment.runs.records(limit: 10) }
        var directRun: AnalysisRunRecord? { runs.first { $0.route == .direct } }
        var trialRun: AnalysisRunRecord? { runs.first { $0.route == .trial } }
    }

    // MARK: Before the run

    @Test(
        "Unknown and free-tier states check first; a not-free state does not",
        arguments: [
            (AnalysisKeyTierStore.State.unknown, 1),
            (.freeTier(day: Date(timeIntervalSince1970: 1_790_000_000)), 1),
            (.notFreeTier, 0),
        ]
    )
    func stateDecidesOnlyWhetherToAsk(state: AnalysisKeyTierStore.State, checks: Int) async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = state
        fixture.environment.tierAnswer = .notFreeTier

        await fixture.run()

        #expect(fixture.environment.tierChecks == checks)
        #expect(fixture.record?.state == .completed)
    }

    @Test("A free-tier answer runs on the trial service with no direct send, and the next run checks again")
    func freeTierAnswerRoutesToTheTrial() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available

        await fixture.run()

        #expect(fixture.record?.state == .completed)
        #expect(fixture.runs.count == 1)
        let run = try #require(fixture.trialRun)
        #expect(run.freeTier == true)
        #expect(run.handoverOf == nil)
        #expect(run.state == .finished)
        #expect(fixture.directRun == nil)
        #expect(fixture.environment.usage.isEmpty)
        #expect(fixture.environment.tierNotes == [.freeTier])

        await fixture.run(transcriptDocument(episodeID: "free-tier-second"))
        #expect(fixture.environment.tierChecks == 2)
    }

    @Test("A not-free answer goes direct and no later run checks")
    func notFreeAnswerGoesDirectAndIsNotAskedAgain() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .notFreeTier

        await fixture.run()
        await fixture.run(transcriptDocument(episodeID: "paid-second"))

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.environment.tierNotes == [.notFreeTier])
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.runs.allSatisfy { $0.route == .direct && $0.freeTier == nil })
    }

    @Test("An inconclusive answer goes direct and leaves the state")
    func inconclusiveAnswerGoesDirect() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .inconclusive

        await fixture.run()

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.environment.googleKeyTier == .unknown)
        #expect(fixture.directRun?.state == .finished)
    }

    @Test(
        "A free-tier answer with the trial not taking it falls through to the direct attempt",
        arguments: [ScriptedAdAnalysisRunEnvironment.HandoverAnswer.unavailable, .notOpen]
    )
    func freeTierAnswerFallsThrough(handover: ScriptedAdAnalysisRunEnvironment.HandoverAnswer) async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = handover

        await fixture.run()

        #expect(fixture.record?.state == .completed)
        #expect(fixture.directRun?.state == .finished)
        #expect(fixture.trialRun == nil)
        // A direct run finished: billing may be set up, so the mark goes.
        #expect(fixture.environment.tierResets == 1)
        #expect(fixture.environment.googleKeyTier == .unknown)
    }

    @Test("No check runs before a run outside the window")
    func noCheckOutsideTheWindow() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = false

        await fixture.run()

        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.record?.state == .completed)
    }

    @Test("A resumed record keeps its route and is not checked")
    func resumedRecordIsNotChecked() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .inconclusive
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        let expired = try #require(fixture.directRun)
        #expect(fixture.environment.tierChecks == 1)

        fixture.environment.answer = .sponsorRead
        await fixture.run()

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.environment.resolvedRunIDs.last == expired.id)
        #expect(fixture.record?.state == .completed)
    }

    // MARK: During the check

    @Test("Remove in AI Services during the check ends the run as needing a key, never as a trial run")
    func removalDuringTheCheck() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.tierCheckGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.tierChecks == 1 })
        #expect(fixture.store.activeDirectProvider == .google)

        fixture.store.cancelActiveRun(reason: .keyRemoved)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.record?.state == .failed)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.environment.sends.count == 0)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("Remove in AI Services during the trial status call ends the run as needing a key")
    func removalDuringTheStatusCall() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.handoverGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.handoverRequests == 1 })

        fixture.store.cancelActiveRun(reason: .keyRemoved)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.environment.sends.count == 0)
    }

    @Test("A cancelled check is never read as an answer: it writes no state and nothing runs")
    func cancelledCheckWritesNothing() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .notFreeTier
        fixture.environment.tierCheckGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.tierChecks == 1 })

        fixture.store.cancelActiveRun(reason: .listener)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.environment.sends.count == 0)
    }

    @Test("A key removed through the Keychain during the check writes no state and takes no trial route")
    func keychainRemovalDuringTheCheck() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onTierCheck = { try? storage.remove(provider: .google, includingSyncedCopy: true) }

        await fixture.run()

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
    }

    @Test("A key replaced through the Keychain during the status call writes no state and takes no trial route")
    func keychainReplacementDuringTheStatusCall() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onHandover = {
            try? storage.save(AnalysisProviderKey("replacement-test-key")!, provider: .google, syncs: false)
        }

        await fixture.run()

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.trialRun == nil)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
    }

    @Test("A key replaced through the Keychain during the check writes no state and takes no trial route")
    func keychainReplacementDuringTheCheck() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onTierCheck = {
            try? storage.save(AnalysisProviderKey("replacement-test-key")!, provider: .google, syncs: false)
        }

        await fixture.run()

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.environment.sends.count == 0)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
    }

    @Test("A key removed through the Keychain during the status call writes no state and takes no trial route")
    func keychainRemovalDuringTheStatusCall() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onHandover = { try? storage.remove(provider: .google, includingSyncedCopy: true) }

        await fixture.run()

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.runs.isEmpty)
        #expect(fixture.environment.sends.count == 0)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
    }

    @Test("An interruption during the status call leaves no run to resume, and a reload finds the last document in place")
    func interruptionDuringTheStatusCallLeavesNoRun() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        try fixture.writeTranscript()
        await fixture.run()
        let original = try #require(fixture.store.document(for: fixture.episodeID))
        let runsBefore = fixture.runs.count
        let sendsBefore = fixture.environment.sends.count

        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.handoverGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.handoverRequests == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.environment.tierNotes.isEmpty)
        #expect(fixture.runs.count == runsBefore)
        #expect(fixture.record?.state == .completed)
        #expect(fixture.store.document(for: fixture.episodeID) == original)

        let relaunched = Fixture.makeStore(directory: fixture.directory, environment: fixture.environment)
        relaunched.load(modelContext: fixture.context)

        #expect(!relaunched.hasActiveJob)
        #expect(relaunched.record(for: fixture.episodeID)?.state == .completed)
        #expect(relaunched.document(for: fixture.episodeID) == original)
        #expect(fixture.runs.count == runsBefore)
        #expect(fixture.environment.sends.count == sendsBefore)
    }

    @Test("An expiry during the check leaves no run record and the last document in place")
    func expiryDuringTheCheckLeavesNoRun() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        await fixture.run()
        let original = try #require(fixture.store.document(for: fixture.episodeID))
        let runsBefore = fixture.runs.count

        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.tierCheckGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.tierChecks == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.runs.count == runsBefore)
        #expect(fixture.record?.state == .completed)
        #expect(fixture.store.document(for: fixture.episodeID) == original)
    }

    // MARK: After a failed direct attempt

    @Test(
        "Each Google-side failure triggers one check",
        arguments: [
            (ScriptedAdAnswer.failure(.retryable(status: 429, retryAfterSeconds: 0), status: 429, listener: .rateLimited), AnalysisProviderFailure.rateLimited),
            (.failure(.quotaExhausted, status: 429, listener: .dailyLimit), .dailyLimit),
            (.failure(.quotaExhausted, status: 429, listener: .billingOrQuota), .billingOrQuota),
            (.failure(.retryable(status: 503, retryAfterSeconds: 0), status: 503, listener: .overloaded), .overloaded),
            (.failure(.timeout, status: nil, listener: .timeout), .timeout),
        ]
    )
    func googleSideFailureChecksOnce(answer: ScriptedAdAnswer, listener: AnalysisProviderFailure) async throws {
        let fixture = try Fixture()
        fixture.environment.answer = answer
        fixture.environment.tierAnswer = .inconclusive

        await fixture.run()

        #expect(fixture.environment.tierChecks == 1, "\(listener)")
        #expect(fixture.record?.state == .failed)
    }

    @Test(
        "No other failure triggers a check",
        arguments: [
            ScriptedAdAnswer.failure(.rejected(status: 400), status: 400, listener: .invalidKey),
            .failure(.rejected(status: 404), status: 404, listener: .modelUnavailable),
            .failure(.rejected(status: 400), status: 400, listener: .requestRejected),
            .failure(.network, status: nil, listener: .unreachable),
            .failure(.oversizedBody, status: 200, listener: .malformedAnswer),
        ]
    )
    func otherFailuresDoNotCheck(answer: ScriptedAdAnswer) async throws {
        let fixture = try Fixture()
        fixture.environment.answer = answer
        fixture.environment.tierAnswer = .freeTier

        await fixture.run()

        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.record?.state == .failed)
    }

    @Test("A run that got a free-tier answer before it started is not asked again")
    func answerBeforeTheRunIsNotAskedAgain() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .unavailable
        fixture.environment.answer = Self.overloaded

        await fixture.run()

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.record?.failureKind == .providerFreeTierRetry)
    }

    @Test("A free-tier answer after a failure hands over inside the window")
    func failureThenFreeTierHandsOver() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.overloaded : .sponsorRead }

        await fixture.run()

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.record?.state == .completed)
        #expect(fixture.record?.failureKind == nil)
        let direct = try #require(fixture.directRun)
        let handover = try #require(fixture.trialRun)
        #expect(direct.state == .failed)
        #expect(direct.listenerFailure == "overloaded")
        #expect(handover.state == .finished)
        #expect(handover.freeTier == true)
        #expect(handover.handoverOf == direct.id)
        #expect(fixture.environment.transportRunIDs == [direct.id, handover.id])
        #expect(fixture.environment.resolvedRunIDs.count == 1)
    }

    @Test("A free-tier answer after a failure fails as free tier outside the window")
    func failureThenFreeTierOutsideTheWindow() async throws {
        let fixture = try Fixture()
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.answer = Self.overloaded

        await fixture.run()

        #expect(fixture.record?.failureKind == .providerFreeTier)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.environment.tierNotes == [.freeTier])
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("A paid answer leaves the failure as it is today and marks the key not free tier")
    func failureThenPaidAnswer() async throws {
        let fixture = try Fixture()
        fixture.environment.tierAnswer = .notFreeTier
        fixture.environment.answer = Self.overloaded

        await fixture.run()

        #expect(fixture.record?.failureKind == .providerLimited)
        #expect(fixture.environment.googleKeyTier == .notFreeTier)
        #expect(fixture.environment.handoverRequests == 0)
    }

    @Test("A daily limit on a key not named free tier says so")
    func dailyLimitOnAPaidKey() async throws {
        let fixture = try Fixture()
        fixture.environment.tierAnswer = .notFreeTier
        fixture.environment.answer = .failure(.quotaExhausted, status: 429, listener: .dailyLimit)

        await fixture.run()

        #expect(fixture.record?.failureKind == .providerDailyLimit)
    }

    @Test("A send naming the free tier needs no check, whatever the listener failure")
    func namedSendNeedsNoCheck() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .notOpen
        fixture.environment.answer = Self.namedFreeTier

        await fixture.run()

        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.environment.tierNotes == [.freeTier])
        #expect(fixture.record?.failureKind == .providerFreeTier)
    }

    @Test("Outside the window a run named free tier fails as free tier and is never handed over")
    func namedSendOutsideTheWindow() async throws {
        let fixture = try Fixture()
        fixture.environment.answer = Self.namedFreeTier

        await fixture.run()

        #expect(fixture.record?.failureKind == .providerFreeTier)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.environment.tierNotes == [.freeTier])
    }

    // MARK: The handover

    @Test("If both attempts fail, the episode's last document is restored")
    func bothAttemptsFailRestoresTheDocument() async throws {
        let fixture = try Fixture()
        await fixture.run()
        let original = try #require(fixture.store.document(for: fixture.episodeID))

        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = Self.namedFreeTier
        await fixture.run()

        #expect(fixture.trialRun?.handoverOf != nil)
        #expect(fixture.record?.state == .completed)
        #expect(fixture.record?.failureKind == .providerFreeTierRetry)
        #expect(fixture.store.document(for: fixture.episodeID) == original)
    }

    @Test("A handover after several successful direct windows runs every window on the trial and counts usage once")
    func handoverAfterSuccessfulWindows() async throws {
        // Four windows: 800 segments, then 680 more for each further one.
        let fixture = try Fixture(segmentCount: 2_161)
        fixture.environment.sendsDirectWindowsInOrder = true
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        let isLastWindow: @Sendable (AnalysisProviderRequest) -> Bool = { $0.purpose == .adWindow(index: 3) }
        let failedOnce = ScriptedFlag()
        let refusal = Self.namedFreeTier
        fixture.environment.answerForRequest = { request in
            guard isLastWindow(request), failedOnce.setOnce() else { return .sponsorRead }
            return refusal
        }

        await fixture.run()

        #expect(fixture.record?.state == .completed)
        let direct = try #require(fixture.directRun)
        let handover = try #require(fixture.trialRun)
        #expect(direct.state == .failed)
        #expect(handover.state == .finished)
        #expect(handover.handoverOf == direct.id)
        // Three direct windows answered, the fourth refused, then all four on
        // the trial: what the direct attempt had answered is not carried across.
        let windows: [AnalysisProviderRequest.Purpose] = (0..<4).map { .adWindow(index: $0) }
        #expect(fixture.environment.sends.all.map(\.purpose) == windows + windows)
        #expect(fixture.environment.transportRunIDs == [direct.id, handover.id])
        // The three answered direct windows, counted once; the trial bills none.
        #expect(fixture.environment.usage.map(\.runID) == [direct.id])
        #expect(fixture.environment.usage.first?.inputTokens == 3 * Int(ScriptedAdAnalysisTransport.usage.input))
    }

    @Test(
        "Every ending of a trial run for a free-tier key gives its kind, with no key screen",
        arguments: [
            (AnalysisProviderFailure.trialExhausted, EpisodeAnalysisFailureKind.providerFreeTier),
            (.trialPaused, .providerFreeTierRetry),
            (.trialUnavailable, .providerFreeTierRetry),
            (.unreachable, .providerFreeTierRetry),
            (.rateLimited, .providerFreeTierRetry),
            (.overloaded, .providerFreeTierRetry),
            (.trialRunBound, .providerFreeTierRunBound),
            (.invalidKey, .providerFreeTierRetry),
            (.billingOrQuota, .providerFreeTierRetry),
            (.dailyLimit, .providerFreeTierRetry),
            (.modelUnavailable, .providerFreeTierRetry),
            (.requestRejected, .generic),
            (.timeout, .timedOut),
            (.malformedAnswer, .generic),
        ]
    )
    func trialEndings(listener: AnalysisProviderFailure, kind: EpisodeAnalysisFailureKind) async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .failure(.rejected(status: 400), status: 400, listener: listener)

        await fixture.run()

        #expect(fixture.trialRun?.freeTier == true)
        #expect(fixture.record?.state == .failed)
        #expect(fixture.record?.failureKind == kind, "\(listener)")
        #expect(fixture.record?.failureKind?.keyRequiredReason == nil)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test(
        "After a failed direct attempt, a handover that cannot start gives its kind",
        arguments: [
            (ScriptedAdAnalysisRunEnvironment.HandoverAnswer.notOpen, EpisodeAnalysisFailureKind.providerFreeTier),
            (.unavailable, .providerFreeTierRetry),
        ]
    )
    func handoverCannotStart(handover: ScriptedAdAnalysisRunEnvironment.HandoverAnswer, kind: EpisodeAnalysisFailureKind) async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = handover

        await fixture.run()

        #expect(fixture.record?.failureKind == kind)
        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("A handover record that cannot be written hands nothing over and ends the direct run as failed")
    func handoverRecordCannotBeWritten() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        let runsDirectory = fixture.environment.runs.directory
        // A file where the records go makes the next write fail.
        fixture.environment.onHandover = {
            try? FileManager.default.removeItem(at: runsDirectory)
            FileManager.default.createFile(atPath: runsDirectory.path(percentEncoded: false), contents: Data())
        }

        await fixture.run()

        #expect(fixture.record?.failureKind == .generic)
        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.transportRunIDs.count == 1)
    }

    @Test("A good trial answer whose document fails to install leaves the run open, and the next start resumes it")
    func failedInstallLeavesTheHandoverOpen() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .sponsorRead }
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: fixture.directory)
        let blocker = fileStore.fileURL(relativePath: fileStore.relativePath(
            episodeID: fixture.episodeID,
            transcriptFingerprint: fileStore.transcriptFingerprint(for: fixture.transcript)
        ))
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blocker.appending(path: "occupied"))

        await fixture.run()

        #expect(fixture.record?.failureKind == .generic)
        let open = try #require(fixture.trialRun)
        #expect(open.state == .dispatched)
        #expect(environmentReplies(fixture, open) == 1)

        try FileManager.default.removeItem(at: blocker)
        let sent = fixture.environment.sends.count
        await fixture.run()

        #expect(fixture.record?.state == .completed)
        #expect(fixture.environment.sends.count == sent)
        #expect(fixture.trialRun?.state == .finished)
    }

    @Test("A listener's cancel during the direct attempt asks nothing and hands nothing over")
    func cancelBeforeTheHandover() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })

        fixture.store.cancelActiveRun(reason: .listener)
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    @Test("An in-app key removal during the direct attempt ends the run as needing a key, asks nothing and hands nothing over")
    func removalBeforeTheHandover() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        #expect(fixture.store.activeDirectProvider == .google)

        fixture.store.cancelActiveRun(reason: .keyRemoved)
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("A key a send found gone wins over the Google-side failure: nothing is asked and nothing handed over")
    func sendFoundTheKeyGoneInsideTheWindow() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture(segmentCount: 900)
        fixture.environment.keyStorage = storage
        fixture.environment.sendsDirectWindowsInOrder = true
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        // Gone once the first window is out, so the second window's send finds it.
        fixture.environment.onSend = { _ in try? storage.remove(provider: .google, includingSyncedCopy: true) }

        await fixture.run()

        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.environment.tierChecks == 0)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    @Test("A send that named the free tier, with the key gone since, ends as needing a key: the finding is not written and nothing is handed over")
    func namedSendWithTheKeyGone() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onSend = { _ in try? storage.remove(provider: .google, includingSyncedCopy: true) }

        await fixture.run()

        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.environment.handoverRequests == 0)
        #expect(fixture.trialRun == nil)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    @Test("A listener's cancel while the handover is being resolved ends the direct run and starts nothing")
    func cancelDuringTheHandover() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.handoverGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.handoverRequests == 1 })

        fixture.store.cancelActiveRun(reason: .listener)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.trialRun == nil)
        #expect(fixture.directRun?.state == .cancelled)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    @Test("An in-app key removal while the handover is being resolved ends the run as needing a key")
    func removalDuringTheHandover() async throws {
        let gate = AsyncTestGate()
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.handoverGate = gate
        fixture.start()
        #expect(await waitUntil { fixture.environment.handoverRequests == 1 })
        #expect(fixture.store.activeDirectProvider == .google)

        fixture.store.cancelActiveRun(reason: .keyRemoved)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.trialRun == nil)
        #expect(fixture.directRun?.listenerFailure == "key_required")
    }

    @Test("Once the handover record is written, a Google key removed through the Keychain does not touch the trial attempt")
    func keychainRemovalDuringTheTrialAttempt() async throws {
        let gate = AsyncTestGate()
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .sponsorRead }
        // Read as each transport is built, so only the trial attempt holds.
        fixture.environment.onHandover = { fixture.environment.gate = gate }
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 2 })
        #expect(fixture.trialRun?.state == .dispatched)

        try storage.remove(provider: .google, includingSyncedCopy: true)
        // What Remove in AI Services finds: no run on this provider to cancel.
        #expect(fixture.store.activeDirectProvider == nil)
        await gate.release()
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        #expect(fixture.record?.state == .completed)
        #expect(fixture.record?.failureKind == nil)
        #expect(fixture.trialRun?.state == .finished)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("Once the handover record is written, removing the Google key no longer concerns the run")
    func removalAfterTheHandoverIsWritten() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .hold }
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 2 })

        #expect(fixture.store.activeDirectProvider == nil)
        fixture.store.cancelActiveRun(reason: .listener)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
    }

    @Test("A key removed through the Keychain while the handover is being resolved hands nothing over")
    func keychainRemovalDuringTheHandover() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onHandover = { try? storage.remove(provider: .google, includingSyncedCopy: true) }

        await fixture.run()

        #expect(fixture.trialRun == nil)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    @Test("A key replaced through the Keychain while the handover is being resolved hands nothing over")
    func keychainReplacementDuringTheHandover() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let fixture = try Fixture()
        fixture.environment.keyStorage = storage
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.onHandover = {
            try? storage.save(AnalysisProviderKey("replacement-test-key")!, provider: .google, syncs: false)
        }

        await fixture.run()

        #expect(fixture.trialRun == nil)
        #expect(fixture.record?.failureKind == .keyRequiredNoKey)
        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.environment.tierNotes.isEmpty)
    }

    // MARK: Recovery

    @Test("A kill before the handover record is written resumes the direct run, which fails again and hands over")
    func killBeforeTheHandoverRecord() async throws {
        let fixture = try Fixture()
        try fixture.writeTranscript()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        let direct = try #require(fixture.directRun)

        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 2 ? Self.namedFreeTier : .sponsorRead }
        let relaunched = Fixture.makeStore(directory: fixture.directory, environment: fixture.environment)
        relaunched.load(modelContext: fixture.context)
        #expect(await waitUntil { !relaunched.hasActiveJob && relaunched.record(for: fixture.episodeID)?.state == .completed })

        #expect(fixture.environment.resolvedRunIDs.last == direct.id)
        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.trialRun?.handoverOf == direct.id)
        #expect(fixture.trialRun?.state == .finished)
    }

    @Test("A kill after the handover record is written closes the direct run, counts it once and resumes the handover")
    func killAfterTheHandoverRecord() async throws {
        let fixture = try Fixture()
        try fixture.writeTranscript()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .hold }
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 2 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        let handover = try #require(fixture.trialRun)
        let direct = try #require(fixture.directRun)
        #expect(handover.state == .expired)
        // As if the process stopped between the two writes.
        fixture.environment.runs.update(runID: direct.id) { record in
            record.state = .dispatched
            record.finishedAt = nil
            record.inputTokens = 100
            record.usageRecorded = nil
        }

        fixture.environment.answerForRun = nil
        fixture.environment.answer = .sponsorRead
        let relaunched = Fixture.makeStore(directory: fixture.directory, environment: fixture.environment)
        relaunched.load(modelContext: fixture.context)
        #expect(await waitUntil { !relaunched.hasActiveJob && relaunched.record(for: fixture.episodeID)?.state == .completed })

        #expect(fixture.directRun?.state == .failed)
        #expect(fixture.environment.resolvedRunIDs.last == handover.id)
        #expect(fixture.trialRun?.state == .finished)
        #expect(fixture.environment.usage.filter { $0.runID == direct.id }.count == 1)
    }

    @Test("Fresh stores read both records from disk at one instant: the handover goes on, and two reloads count the direct run once")
    func killAfterTheHandoverRecordWithEqualTimestamps() async throws {
        let fixture = try Fixture()
        try fixture.writeTranscript()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .hold }
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 2 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        let handover = try #require(fixture.trialRun)
        let direct = try #require(fixture.directRun)
        // As if the process stopped between the two writes.
        fixture.environment.runs.update(runID: direct.id) { record in
            record.state = .dispatched
            record.finishedAt = nil
            record.inputTokens = 100
            record.usageRecorded = nil
        }
        let directory = fixture.environment.runs.directory
        // The direct run's own start: an older one would be past the resume TTL.
        try Self.rewriteStart(of: [direct.id, handover.id], to: direct.startedAt.ISO8601Format(), in: directory)

        func relaunchedEnvironment() -> ScriptedAdAnalysisRunEnvironment {
            let environment = ScriptedAdAnalysisRunEnvironment(directory: directory)
            environment.handoverWindowOpen = true
            return environment
        }
        let launch = relaunchedEnvironment()
        #expect(launch.runs.record(id: direct.id)?.startedAt == launch.runs.record(id: handover.id)?.startedAt)
        let relaunched = Fixture.makeStore(directory: fixture.directory, environment: launch)
        relaunched.load(modelContext: fixture.context)
        #expect(await waitUntil { !relaunched.hasActiveJob && relaunched.record(for: fixture.episodeID)?.state == .completed })

        #expect(launch.resolvedRunIDs == [handover.id])
        #expect(launch.runs.record(id: direct.id)?.state == .failed)
        #expect(launch.runs.record(id: handover.id)?.state == .finished)
        #expect(launch.usage.map(\.runID) == [direct.id])
        #expect(launch.usage.first?.inputTokens == 100)

        let secondLaunch = relaunchedEnvironment()
        let reloaded = Fixture.makeStore(directory: fixture.directory, environment: secondLaunch)
        reloaded.load(modelContext: fixture.context)

        #expect(!reloaded.hasActiveJob)
        #expect(secondLaunch.usage.isEmpty)
        #expect(secondLaunch.resolvedRunIDs.isEmpty)
        #expect(secondLaunch.runs.record(id: direct.id)?.state == .failed)
    }

    /// Dates persist at ISO 8601 precision, so two writes in one second read
    /// back equal; `startedAt` itself cannot change once a record is begun.
    private static func rewriteStart(of runIDs: [String], to date: String, in directory: URL) throws {
        for runID in runIDs {
            let url = directory.appending(path: "\(runID).json", directoryHint: .notDirectory)
            var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["started_at"] = date
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
    }

    @Test("A handover expired in the background resumes with its failure policy and its flag")
    func expiredHandoverResumes() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        #expect(fixture.store.analysisProgress(for: fixture.episodeID)?.isFreeTierTrial == true)
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        let expired = try #require(fixture.trialRun)
        #expect(expired.state == .expired)

        fixture.environment.answer = .failure(.rejected(status: 503), status: 503, listener: .trialPaused)
        await fixture.run()

        #expect(fixture.environment.resolvedRunIDs.last == expired.id)
        #expect(fixture.record?.failureKind == .providerFreeTierRetry)
        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    @Test("A resume is refused past the date and fails as free tier, sending nothing")
    func resumeRefusedOutsideTheWindow() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        fixture.environment.handoverWindowOpen = false
        fixture.environment.isPastTrialDate = true
        fixture.environment.answer = .sponsorRead
        await fixture.run()

        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.record?.failureKind == .providerFreeTier)
        #expect(fixture.trialRun?.state == .cancelled)
    }

    @Test("A free-tier run whose exchange is gone at resume never reads as needing a key")
    func resumeWithNoExchange() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })

        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .keyRequired(.proxyUnavailable)
        await fixture.run()

        #expect(fixture.record?.failureKind == .providerFreeTierRetry)
        #expect(fixture.environment.presentedReasons.isEmpty)
    }

    /// A free-tier run expired on the trial service with its record open,
    /// and the episode's record still running, as a kill leaves them.
    private func expiredFreeTierRun(_ fixture: Fixture) async throws -> AnalysisRunRecord {
        try fixture.writeTranscript()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answer = .hold
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 1 })
        fixture.store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
        fixture.environment.answer = .sponsorRead
        return try #require(fixture.trialRun)
    }

    /// Reloads as a launch does and waits for the resume to end.
    private func relaunch(_ fixture: Fixture) async -> EpisodeAdAnalysisStore {
        let relaunched = Fixture.makeStore(directory: fixture.directory, environment: fixture.environment)
        relaunched.load(modelContext: fixture.context)
        #expect(await waitUntil { !relaunched.hasActiveJob && relaunched.record(for: fixture.episodeID)?.state != .running })
        return relaunched
    }

    @Test("At launch inside the window, an exchange that is gone reads as try again later: no key screen, nothing interrupted, the run left open")
    func launchWithNoExchangeInsideTheWindow() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .keyRequired(.proxyUnavailable)
        let relaunched = await relaunch(fixture)

        #expect(relaunched.record(for: fixture.episodeID)?.failureKind == .providerFreeTierRetry)
        #expect(fixture.environment.presentedReasons.isEmpty)
        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .expired)
    }

    @Test("At launch past the date, an exchange that is gone closes the run and fails as free tier")
    func launchWithNoExchangeOutsideTheWindow() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.handoverWindowOpen = false
        fixture.environment.isPastTrialDate = true
        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .keyRequired(.proxyUnavailable)
        let relaunched = await relaunch(fixture)

        #expect(relaunched.record(for: fixture.episodeID)?.failureKind == .providerFreeTier)
        #expect(fixture.environment.presentedReasons.isEmpty)
        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .cancelled)
    }

    @Test("A manual retry past the date with the exchange gone closes the run and fails as free tier, the window read first")
    func retryWithNoExchangeOutsideTheWindow() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.handoverWindowOpen = false
        fixture.environment.isPastTrialDate = true
        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .keyRequired(.proxyUnavailable)
        await fixture.run()

        #expect(fixture.record?.failureKind == .providerFreeTier)
        #expect(fixture.environment.presentedReasons.isEmpty)
        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .cancelled)
    }

    @Test(
        "Before the date a service out of reach tries again later and leaves the run open, on a launch and on a retry, with the exchange there or gone",
        arguments: [true, false], [true, false]
    )
    func outOfReachBeforeTheDate(isLaunch: Bool, exchangeGone: Bool) async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.handoverWindowOpen = false
        if exchangeGone {
            fixture.environment.keepsResumedRoute = false
            fixture.environment.route = .keyRequired(.proxyUnavailable)
        }
        let kind: EpisodeAnalysisFailureKind?
        if isLaunch {
            kind = await relaunch(fixture).record(for: fixture.episodeID)?.failureKind
        } else {
            await fixture.run()
            kind = fixture.record?.failureKind
        }

        #expect(kind == .providerFreeTierRetry)
        #expect(fixture.environment.presentedReasons.isEmpty)
        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .expired)
    }

    @Test("A run left open while the service was out of reach resumes once it is back")
    func outOfReachRunResumesLater() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)
        fixture.environment.handoverWindowOpen = false
        await fixture.run()
        #expect(fixture.record?.failureKind == .providerFreeTierRetry)

        fixture.environment.handoverWindowOpen = true
        await fixture.run()

        #expect(fixture.record?.state == .completed)
        #expect(fixture.environment.resolvedRunIDs.last == run.id)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .finished)
        #expect(fixture.runs.count == 1)
    }

    @Test("A launch never replaces a free-tier run whose route no longer applies")
    func launchNeverReplacesAFreeTierRun() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .direct(provider: .google)
        let relaunched = await relaunch(fixture)

        #expect(relaunched.record(for: fixture.episodeID)?.failureKind == .interrupted)
        #expect(fixture.environment.sends.count == 1)
        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.runs.count == 1)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .expired)
    }

    @Test("A manual start whose route no longer resumes a free-tier run closes it and runs anew, whatever the window")
    func manualStartReplacesARunThatNoLongerApplies() async throws {
        let fixture = try Fixture()
        let run = try await expiredFreeTierRun(fixture)

        fixture.environment.handoverWindowOpen = false
        fixture.environment.keepsResumedRoute = false
        fixture.environment.route = .direct(provider: .google)
        await fixture.run()

        #expect(fixture.record?.state == .completed)
        #expect(fixture.environment.runs.record(id: run.id)?.state == .cancelled)
        #expect(fixture.directRun?.state == .finished)
    }

    // MARK: Progress

    @Test("A late callback from the direct attempt does not move the handover's progress")
    func lateDirectCallback() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.answerForRun = { $0 == 1 ? Self.namedFreeTier : .hold }
        fixture.start()
        #expect(await waitUntil { fixture.environment.sends.count == 2 })
        let direct = try #require(fixture.directRun)
        let handover = try #require(fixture.trialRun)
        let observer = try #require(fixture.environment.observers[direct.id])
        let handoverObserver = try #require(fixture.environment.observers[handover.id])
        #expect(fixture.store.analysisProgress(for: fixture.episodeID)?.attemptID == handover.id)
        #expect(fixture.store.analysisProgress(for: fixture.episodeID)?.isFreeTierTrial == true)

        // Alone, and drained: the steps count by purpose, so sent beside the
        // handover's own callback it would be hidden in the same count.
        observer.record(Self.answeredSend)
        await drainMainActorHops()
        #expect(fixture.store.analysisProgress(for: fixture.episodeID)?.completed == 0)

        handoverObserver.record(Self.answeredSend)
        await drainMainActorHops()
        #expect(fixture.store.analysisProgress(for: fixture.episodeID)?.completed == 1)

        fixture.store.cancelActiveRun(reason: .listener)
        #expect(await waitUntil { !fixture.store.hasActiveJob })
    }

    /// A send's callback hops to the main actor in a task of its own; a task
    /// queued after it runs after it.
    private func drainMainActorHops() async {
        for _ in 0..<3 {
            await Task { @MainActor in }.value
        }
    }

    private static let answeredSend = AnalysisProviderSendRecord(
        provider: .google,
        modelID: "gemini-3.8-flash",
        feature: .adDetection,
        purpose: .adWindow(index: 0),
        sendIndex: 0,
        status: 200,
        finishReason: .stop,
        failure: nil,
        usage: nil,
        pacedSeconds: 0,
        exchangeSeconds: 0
    )

    // MARK: The day Google answered

    private static let answerDay = Date(timeIntervalSince1970: 1_793_000_000)
    private static let nextDay = answerDay.addingTimeInterval(86_400)

    @Test("A status call that returns the next day leaves the day Google answered")
    func statusCallCrossingMidnight() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available
        fixture.environment.now = Self.answerDay
        fixture.environment.onHandover = { fixture.environment.now = Self.nextDay }

        await fixture.run()

        #expect(fixture.environment.googleKeyTier == .freeTier(day: Self.answerDay))
    }

    @Test("A pre-run answer reused after a failed attempt keeps its time")
    func reusedAnswerKeepsItsTime() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .unavailable
        fixture.environment.answer = Self.overloaded
        fixture.environment.now = Self.answerDay
        fixture.environment.onHandover = { fixture.environment.now = Self.nextDay }

        await fixture.run()

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.environment.tierNotes == [.freeTier, .freeTier])
        #expect(fixture.environment.googleKeyTier == .freeTier(day: Self.answerDay))
    }

    @Test("A send that named the free tier keeps the time the run ended, not the time the status call returned")
    func namedSendKeepsItsTime() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.answer = Self.namedFreeTier
        fixture.environment.handoverAnswer = .unavailable
        fixture.environment.now = Self.answerDay
        fixture.environment.onHandover = { fixture.environment.now = Self.nextDay }

        await fixture.run()

        #expect(fixture.environment.googleKeyTier == .freeTier(day: Self.answerDay))
    }

    @Test("A check made after a failed attempt keeps the time it answered")
    func checkAfterAFailureKeepsItsTime() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.googleKeyTier = .notFreeTier
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .unavailable
        fixture.environment.answer = Self.overloaded
        fixture.environment.now = Self.answerDay
        fixture.environment.onHandover = { fixture.environment.now = Self.nextDay }

        await fixture.run()

        #expect(fixture.environment.tierChecks == 1)
        #expect(fixture.environment.googleKeyTier == .freeTier(day: Self.answerDay))
    }

    // MARK: The state after a run

    @Test("A direct Google run that completes while the state is free tier resets it")
    func completionResetsAStaleMark() async throws {
        let fixture = try Fixture()
        fixture.environment.googleKeyTier = .freeTier(day: .now)

        await fixture.run()

        #expect(fixture.environment.tierResets == 1)
        #expect(fixture.environment.googleKeyTier == .unknown)
    }

    @Test("A trial run for a free-tier key leaves the mark where it is")
    func trialCompletionKeepsTheMark() async throws {
        let fixture = try Fixture()
        fixture.environment.handoverWindowOpen = true
        fixture.environment.tierAnswer = .freeTier
        fixture.environment.handoverAnswer = .available

        await fixture.run()

        #expect(fixture.environment.tierResets == 0)
        if case .freeTier = fixture.environment.googleKeyTier {} else {
            Issue.record("the mark went: \(fixture.environment.googleKeyTier)")
        }
    }

    private func environmentReplies(_ fixture: Fixture, _ run: AnalysisRunRecord) -> Int {
        fixture.environment.runs.replies(runID: run.id).count
    }
}

/// True once, for a send answered from any thread.
private final class ScriptedFlag: Sendable {
    private let state = Mutex(false)

    func setOnce() -> Bool {
        state.withLock { wasSet in
            defer { wasSet = true }
            return !wasSet
        }
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func transcriptDocument(episodeID: String, segmentCount: Int = 2) -> EpisodeTranscriptDocument {
    let segments = (0..<segmentCount).map { index in
        OpenCastTranscriptSegment(
            id: index,
            start: Double(index * 6),
            end: Double(index * 6 + 6),
            text: index == 1 ? "This episode is brought to you by Example Sponsor." : "Segment \(index) of the talk.",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }
    let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
    return EpisodeTranscriptDocument(
        schemaVersion: 1,
        episodeID: episodeID,
        podcastID: "https://example.com/feed.xml",
        sourceAudioURL: "https://example.com/\(episodeID).mp3",
        sourceFileByteCount: 987_654_321,
        sourceFileSHA256: "source-sha",
        modelIdentifier: "model",
        modelVersion: "v1",
        modelTreeSHA256: "tree-sha",
        languageCode: "en",
        audioDuration: Double(segmentCount * 6),
        checkpoints: [],
        segments: segments,
        text: segments.map(\.text).joined(separator: " "),
        timings: EpisodeTranscriptTimings(),
        createdAt: updatedAt.addingTimeInterval(-10),
        updatedAt: updatedAt
    )
}
