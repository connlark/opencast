import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad analysis store")
struct EpisodeAdAnalysisStoreTests {
    @Test("Creates ad analysis record and document from client response")
    func createsAdAnalysisRecordAndDocumentFromClientResponse() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(client: client, fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "ad-create")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let request = try #require(client.lastRequest)
        let encodedRequest = try encodedJSONString(request)
        #expect(record.spanCount == 1)
        #expect(record.transcriptState == .completed)
        #expect(document.spans.first?.label == "Example Sponsor")
        #expect(document.transcriptSegmentCount == transcript.segments.count)
        #expect(document.transcriptState == .completed)
        #expect(request.transcript.state == "completed")
        #expect(request.asyncSupported == true)
        #expect(encodedRequest.contains(#""async_supported":true"#))
        #expect(request.segments.map(\.text) == transcript.segments.map(\.text))
        #expect(encodedRequest.contains(transcript.segments[1].text))
        #expect(encodedRequest.contains(request.transcript.fingerprint))
        #expect(!encodedRequest.contains(transcript.sourceAudioURL))
        #expect(!encodedRequest.contains(transcript.sourceFileSHA256))
        #expect(!encodedRequest.contains(String(transcript.sourceFileByteCount)))
        #expect(!encodedRequest.contains("\"sourceAudioURL\""))
        #expect(!encodedRequest.contains("\"sourceFileSHA256\""))
        #expect(!encodedRequest.contains("\"sourceFileByteCount\""))
        #expect(!encodedRequest.contains("\"source_audio_url\""))
        #expect(!encodedRequest.contains("\"source_file_sha256\""))
        #expect(!encodedRequest.contains("\"source_file_byte_count\""))
    }

    @Test("Normalizes tiny transcript overlap before client request")
    func normalizesTinyTranscriptOverlapBeforeClientRequest() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        var transcript = makeTranscriptDocument(episodeID: "ad-overlap")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 1922,
                start: 8755.3935546875,
                end: 8760.3935546875,
                text: "Only that the goal is to tamper with numerical results.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1923,
                start: 8760.3916015625,
                end: 8767.3916015625,
                text: "not unauthorized access, not malware propagation, or other common malware objectives.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let request = try #require(client.lastRequest)
        #expect(request.transcript.segmentCount == 2)
        #expect(request.segments.map(\.id) == [0, 1])
        #expect(request.segments[0].end == 8760.3935546875)
        #expect(request.segments[1].start == 8760.3935546875)
        #expect(request.segments[1].end == 8767.3916015625)
    }

    @Test("Drops blank transcript segments before client request")
    func dropsBlankTranscriptSegmentsBeforeClientRequest() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(client: client, fileStore: fileStore)
        var transcript = makeTranscriptDocument(episodeID: "ad-blank-segments")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 40,
                start: 0,
                end: 4,
                text: "  Welcome back to the show.  ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 41,
                start: 4,
                end: 5,
                text: "   ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 42,
                start: 5,
                end: 6,
                text: "\n\t",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 43,
                start: 6,
                end: 11,
                text: "Back to the episode.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let request = try #require(client.lastRequest)
        #expect(request.transcript.segmentCount == 2)
        #expect(request.segments.map(\.id) == [0, 1])
        #expect(request.segments.map(\.text) == [
            "Welcome back to the show.",
            "Back to the episode."
        ])
        #expect(record.transcriptSegmentCount == 2)
        #expect(document.transcriptSegmentCount == 2)
        #expect(document.transcriptFingerprint == fileStore.transcriptFingerprint(for: transcript))
    }

    @Test("Blank-only transcript is unavailable for analysis")
    func blankOnlyTranscriptIsUnavailableForAnalysis() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        var transcript = makeTranscriptDocument(episodeID: "ad-blank-only")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 80,
                start: 0,
                end: 2,
                text: " \n\t ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        if case .unavailable(let message) = store.jobState(for: transcript) {
            #expect(message == "Transcript has no segments.")
        } else {
            Issue.record("Expected unavailable state for blank-only transcript.")
        }

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob
        })

        #expect(client.lastRequest == nil)
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(store.lastErrorMessage(for: transcript.episodeID) == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
    }

    @Test("Unavailable backend hides analysis start and avoids client calls")
    func unavailableBackendHidesAnalysisStartAndAvoidsClientCalls() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory),
            analysisUnavailableMessage: "Promo/ad analysis is not configured on this device."
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-unavailable")

        #expect(!store.canStartAnalysis)
        if case .unavailable(let message) = store.jobState(for: transcript) {
            #expect(message == "Promo/ad analysis is not configured on this device.")
        } else {
            Issue.record("Expected unavailable state.")
        }

        store.startAnalysis(transcript: transcript, modelContext: context)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(client.lastRequest == nil)
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(!store.hasActiveJob)
        #expect(store.lastErrorMessage(for: transcript.episodeID) == "Promo/ad analysis is not configured on this device.")
    }

    @Test("App model refuses ad analysis for non-completed transcript records")
    func appModelRefusesAdAnalysisForNonCompletedTranscriptRecords() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let client = FakeEpisodeAdAnalysisClient()
        let adAnalyses = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-incomplete-transcript")

        _ = try writeTranscript(
            transcript,
            fileStore: transcriptFileStore,
            modelContext: context,
            state: .interrupted
        )
        transcriptions.load(modelContext: context)

        if case .unavailable(let message) = adAnalyses.jobState(
            for: transcript,
            transcriptState: transcriptions.record(for: transcript.episodeID)?.state
        ) {
            #expect(message == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
        } else {
            Issue.record("Expected unavailable state for incomplete transcript.")
        }

        appModel.analyzeEpisodeTranscript(transcript, modelContext: context)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(client.lastRequest == nil)
        #expect(adAnalyses.record(for: transcript.episodeID) == nil)
        #expect(!adAnalyses.hasActiveJob)
        #expect(adAnalyses.lastErrorMessage(for: transcript.episodeID) == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
    }

    @Test("Active analysis reports running and blocks another analysis")
    func activeAnalysisReportsRunningAndBlocksAnotherAnalysis() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = HangingEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let firstTranscript = makeTranscriptDocument(episodeID: "ad-active-first")
        let secondTranscript = makeTranscriptDocument(episodeID: "ad-active-second")

        store.startAnalysis(transcript: firstTranscript, modelContext: context)

        #expect(store.hasActiveJob)
        if case .running = store.jobState(for: firstTranscript) {
        } else {
            Issue.record("Expected first analysis to be running.")
        }

        store.startAnalysis(transcript: secondTranscript, modelContext: context)

        #expect(store.record(for: secondTranscript.episodeID) == nil)
        #expect(store.lastErrorMessage(for: secondTranscript.episodeID) == EpisodeAdAnalysisError.anotherJobActive.localizedDescription)

        await client.release()

        #expect(await waitUntil {
            store.record(for: firstTranscript.episodeID)?.state == .completed
        })
        let requestCount = await client.currentRequestCount()
        #expect(requestCount == 1)
        #expect(!store.hasActiveJob)
    }

    @Test("Store reports running while normalization and fingerprint preparation is held")
    func reportsRunningDuringHeldPreparation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            preparationGate: {
                await gate.wait()
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-held-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(store.hasActiveJob)
        #expect(store.record(for: transcript.episodeID) == nil)
        if case .running = store.jobState(for: transcript) {
        } else {
            Issue.record("Expected running while preparation is held.")
        }
        #expect(client.lastRequest == nil)

        await gate.release()

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
    }

    @Test("Cancellation during held preparation performs no request or persistence")
    func cancellationDuringHeldPreparation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            preparationGate: {
                await gate.wait()
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-cancelled-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)
        store.cancelActiveJob()
        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob
        })
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(client.lastRequest == nil)
    }

    @Test("Preparation failure clears running state and surfaces the error")
    func preparationFailureSurfacesError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let client = FakeEpisodeAdAnalysisClient()
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            preparationGate: {
                await gate.wait()
                throw EpisodeAdAnalysisError.transcriptNotCompleted
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-failed-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(store.hasActiveJob)
        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob
        })
        #expect(
            store.lastErrorMessage(for: transcript.episodeID)
                == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription
        )
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(client.lastRequest == nil)
    }

    @Test("Nuke cancels active analysis and removes running record")
    func nukeCancelsActiveAnalysisAndRemovesRunningRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = HangingEpisodeAdAnalysisClient()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(client: client, fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "ad-active-nuke")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(store.hasActiveJob)

        try await store.nukeAllAnalyses(modelContext: context)

        #expect(!store.hasActiveJob)
        #expect(store.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))
    }

    @Test("Backend configuration resolves debug environment and disabled release config")
    func backendConfigurationResolvesDebugEnvironmentAndDisabledReleaseConfig() {
        #if DEBUG
        let defaultDebug = AdAnalysisBackendConfiguration.debug(environment: [:])
        #expect(defaultDebug.workerBaseURL.absoluteString == "https://ad-analysis.example.com/development")
        #expect(defaultDebug.isEnabled)
        #expect(defaultDebug.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.development
        ))
        #expect(defaultDebug.analysisUnavailableMessage(appAttestSupported: false) == EpisodeAdAnalysisError.appAttestUnavailable.localizedDescription)
        #expect(defaultDebug.analysisUnavailableMessage(appAttestSupported: true) == nil)

        let overrideDebug = AdAnalysisBackendConfiguration.debug(environment: [
            "OPENCAST_AD_ANALYSIS_BASE_URL": "  https://staging.example  ",
            "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "  test-token  "
        ])
        #expect(overrideDebug.workerBaseURL.absoluteString == "https://staging.example")
        #expect(overrideDebug.authentication == .bearer(clientToken: "test-token"))
        #expect(overrideDebug.isEnabled)
        #expect(overrideDebug.analysisUnavailableMessage == nil)

        let invalidOverride = AdAnalysisBackendConfiguration.debug(environment: [
            "OPENCAST_AD_ANALYSIS_BASE_URL": "worker.example",
            "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "   "
        ])
        #expect(invalidOverride.workerBaseURL.absoluteString == "https://ad-analysis.example.com/development")
        #expect(invalidOverride.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.development
        ))
        #expect(invalidOverride.analysisUnavailableMessage(appAttestSupported: false) == EpisodeAdAnalysisError.appAttestUnavailable.localizedDescription)
        #endif

        let release = AdAnalysisBackendConfiguration.production
        #expect(release.workerBaseURL.absoluteString == "https://ad-analysis.example.com")
        #expect(release.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.production
        ))
        #expect(release.isEnabled)
        #expect(release.analysisUnavailableMessage(appAttestSupported: true) == nil)

        let prodStaging = AdAnalysisBackendConfiguration.prodStaging
        #expect(prodStaging.workerBaseURL.absoluteString == "https://ad-analysis.example.com/prod-staging")
        #expect(prodStaging.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.prodStaging
        ))
        #expect(prodStaging.isEnabled)
    }

    @Test("Ad analysis record is local-only but included in full schema")
    func adAnalysisRecordIsLocalOnlyButIncludedInFullSchema() {
        #expect(OpenCastModelContainerFactory.localSchema.entitiesByName["EpisodeAdAnalysisRecord"] != nil)
        #expect(OpenCastModelContainerFactory.fullSchema.entitiesByName["EpisodeAdAnalysisRecord"] != nil)
        #expect(OpenCastModelContainerFactory.syncedSchema.entitiesByName["EpisodeAdAnalysisRecord"] == nil)
    }

    @Test("Marks completed analysis stale when transcript fingerprint inputs change")
    func marksCompletedAnalysisStaleWhenTranscriptFingerprintInputsChange() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-stale")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let updatedTranscript = makeTranscriptDocument(
            episodeID: "ad-stale",
            updatedAt: transcript.updatedAt.addingTimeInterval(30),
            extraSegmentText: "new segment"
        )

        if case .completed(_, let isStale) = store.jobState(for: updatedTranscript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed analysis stale when only transcript text changes")
    func marksCompletedAnalysisStaleWhenOnlyTranscriptTextChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-fingerprint-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let updatedTranscript = makeTranscriptDocument(
            episodeID: "ad-fingerprint-stale",
            updatedAt: transcript.updatedAt,
            sponsorSegmentText: "Different sponsor copy with the same segment count."
        )

        if case .completed(_, let isStale) = store.jobState(for: updatedTranscript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed analysis stale when stored transcript state is not completed")
    func marksCompletedAnalysisStaleWhenStoredTranscriptStateIsNotCompleted() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-state-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let record = try #require(store.record(for: transcript.episodeID))
        record.transcriptState = .interrupted

        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed ads_only analysis outdated and re-run overwrites it")
    func marksCompletedAdsOnlyAnalysisOutdatedAndRerunOverwrites() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-policy-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let record = try #require(store.record(for: transcript.episodeID))
        // Rewrite the stored analysis as a pre-step-4 ads_only result whose
        // transcript inputs are still perfectly current.
        record.policy = "ads_only"
        var document = try #require(store.document(for: transcript.episodeID))
        document.policy = "ads_only"
        let relativePath = try #require(record.analysisRelativePath)
        try EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
            .write(document, relativePath: relativePath)

        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state for ads_only policy.")
        }
        #expect(!store.isCurrentAnalysisDocument(document, for: transcript))

        // A manual re-run overwrites the outdated document and clears staleness.
        await startAndWait(store: store, transcript: transcript, modelContext: context)
        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(!isStale)
        } else {
            Issue.record("Expected completed current state after re-run.")
        }
        let rerunDocument = try #require(store.document(for: transcript.episodeID))
        #expect(rerunDocument.policy == EpisodeAdAnalysisContract.expectedPolicy)
        #expect(store.isCurrentAnalysisDocument(rerunDocument, for: transcript))
    }

    @Test("Cloud-imported analysis stays current against the disk round-tripped transcript")
    func cloudImportedAnalysisStaysCurrentAfterTranscriptRoundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        // The cloud pass maps the analysis from the in-memory transcript,
        // whose minted `updatedAt` can carry fractional seconds that the
        // `.iso8601` disk round trip drops.
        let inMemoryTranscript = makeTranscriptDocument(
            episodeID: "ad-cloud-round-trip",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000.742)
        )
        let success = OpenCastRemoteTranscriptionAdAnalysisSuccess(
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [OpenCastRemoteTranscriptionAdAnalysisSpan(
                kind: "host_read_ad",
                label: "Sponsor",
                startSegmentID: 1,
                endSegmentID: 1,
                startTime: 5,
                endTime: 12,
                confidence: 0.9,
                evidenceQuote: "brought to you by"
            )],
            warnings: []
        )
        let analysisDocument = try EpisodeRemoteAdAnalysisMapper.document(
            from: success,
            transcript: inMemoryTranscript,
            requestID: "job-cloud-round-trip"
        )

        try store.importCompletedAnalysis(analysisDocument, modelContext: context)

        let reloadedTranscript = makeTranscriptDocument(
            episodeID: "ad-cloud-round-trip",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        if case .completed(_, let isStale) = store.jobState(for: reloadedTranscript) {
            #expect(!isStale)
        } else {
            Issue.record("Expected completed current state after cloud import.")
        }
    }

    @Test("Current document check requires matching fingerprint metadata")
    func currentDocumentCheckRequiresMatchingFingerprintMetadata() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-current-document")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let analysisDocument = try #require(store.document(for: transcript.episodeID))

        #expect(store.isCurrentAnalysisDocument(analysisDocument, for: transcript))
        var interruptedStateDocument = analysisDocument
        interruptedStateDocument.transcriptState = .interrupted
        #expect(!store.isCurrentAnalysisDocument(interruptedStateDocument, for: transcript))

        let textChangedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt,
            sponsorSegmentText: "Same timing and segment count but different words."
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: textChangedTranscript))

        let updatedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt.addingTimeInterval(30)
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: updatedTranscript))

        let segmentCountChangedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt,
            extraSegmentText: "Extra transcript segment."
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: segmentCountChangedTranscript))
    }

    @Test("Deletes ad analysis record and sidecar")
    func deletesAdAnalysisRecordAndSidecar() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: fileStore
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-delete")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let relativePath = try #require(store.record(for: transcript.episodeID)?.analysisRelativePath)
        #expect(fileStore.documentExists(relativePath: relativePath))
        let orphanRelativePath = "\(EpisodeAdAnalysisFileStore.directoryName)/\(fileStore.safeStem(transcript.episodeID))/orphan.json"
        let orphanURL = fileStore.fileURL(relativePath: orphanRelativePath)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: orphanURL)
        #expect(fileStore.documentExists(relativePath: orphanRelativePath))

        store.deleteAnalysis(episodeID: transcript.episodeID, modelContext: context)

        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(!fileStore.documentExists(relativePath: relativePath))
        #expect(!fileStore.documentExists(relativePath: orphanRelativePath))
    }

    @Test("App model transcript deletion removes transcript and ad analysis sidecars")
    func appModelTranscriptDeletionRemovesTranscriptAndAdAnalysisSidecars() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let adAnalyses = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: adAnalysisFileStore
        )
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-app-delete-transcript")
        let transcriptRelativePath = try writeTranscript(
            transcript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        transcriptions.load(modelContext: context)
        await startAndWait(store: adAnalyses, transcript: transcript, modelContext: context)
        let analysisRelativePath = try #require(adAnalyses.record(for: transcript.episodeID)?.analysisRelativePath)
        #expect(transcriptFileStore.documentExists(relativePath: transcriptRelativePath))
        #expect(adAnalysisFileStore.documentExists(relativePath: analysisRelativePath))

        appModel.deleteEpisodeTranscript(episodeID: transcript.episodeID, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).isEmpty)
        #expect(!transcriptFileStore.documentExists(relativePath: transcriptRelativePath))
        #expect(!adAnalysisFileStore.documentExists(relativePath: analysisRelativePath))
        #expect(appModel.transcriptions.record(for: transcript.episodeID) == nil)
        #expect(appModel.adAnalyses.record(for: transcript.episodeID) == nil)
    }

    @Test("Deletes ad analyses for one podcast and preserves other podcasts")
    func deletesAdAnalysesForPodcast() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: fileStore
        )
        let firstTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-delete-1",
            podcastID: "https://example.com/delete.xml"
        )
        let secondTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-delete-2",
            podcastID: "https://example.com/delete.xml"
        )
        let preservedTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-preserved",
            podcastID: "https://example.com/preserved.xml"
        )

        await startAndWait(store: store, transcript: firstTranscript, modelContext: context)
        await startAndWait(store: store, transcript: secondTranscript, modelContext: context)
        await startAndWait(store: store, transcript: preservedTranscript, modelContext: context)
        let firstPath = try #require(store.record(for: firstTranscript.episodeID)?.analysisRelativePath)
        let secondPath = try #require(store.record(for: secondTranscript.episodeID)?.analysisRelativePath)
        let preservedPath = try #require(store.record(for: preservedTranscript.episodeID)?.analysisRelativePath)
        let orphanRelativePath = "\(EpisodeAdAnalysisFileStore.directoryName)/\(fileStore.safeStem(firstTranscript.episodeID))/orphan.json"
        let orphanURL = fileStore.fileURL(relativePath: orphanRelativePath)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: orphanURL)
        #expect(fileStore.documentExists(relativePath: orphanRelativePath))

        try store.deleteAnalyses(
            forPodcastID: "https://example.com/delete.xml",
            modelContext: context
        )

        #expect(store.record(for: firstTranscript.episodeID) == nil)
        #expect(store.record(for: secondTranscript.episodeID) == nil)
        #expect(store.record(for: preservedTranscript.episodeID)?.state == .completed)
        #expect(!fileStore.documentExists(relativePath: firstPath))
        #expect(!fileStore.documentExists(relativePath: secondPath))
        #expect(!fileStore.documentExists(relativePath: orphanRelativePath))
        #expect(fileStore.documentExists(relativePath: preservedPath))
    }

    @Test("App model unsubscribe removes transcript and ad analysis sidecars for podcast")
    func appModelUnsubscribeRemovesTranscriptAndAdAnalysisSidecarsForPodcast() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let adAnalyses = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: adAnalysisFileStore
        )
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let removedFeedURL = "https://example.com/app-unsubscribe-remove.xml"
        let keptFeedURL = "https://example.com/app-unsubscribe-keep.xml"
        let removedTranscript = makeTranscriptDocument(
            episodeID: "ad-app-unsubscribe-remove",
            podcastID: removedFeedURL
        )
        let keptTranscript = makeTranscriptDocument(
            episodeID: "ad-app-unsubscribe-keep",
            podcastID: keptFeedURL
        )
        let removedTranscriptPath = try writeTranscript(
            removedTranscript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        let keptTranscriptPath = try writeTranscript(
            keptTranscript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        transcriptions.load(modelContext: context)
        await startAndWait(store: adAnalyses, transcript: removedTranscript, modelContext: context)
        await startAndWait(store: adAnalyses, transcript: keptTranscript, modelContext: context)
        let removedAnalysisPath = try #require(adAnalyses.record(for: removedTranscript.episodeID)?.analysisRelativePath)
        let keptAnalysisPath = try #require(adAnalyses.record(for: keptTranscript.episodeID)?.analysisRelativePath)

        await appModel.unsubscribe(feedURL: removedFeedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).map(\.episodeID) == [keptTranscript.episodeID])
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).map(\.episodeID) == [keptTranscript.episodeID])
        #expect(!transcriptFileStore.documentExists(relativePath: removedTranscriptPath))
        #expect(transcriptFileStore.documentExists(relativePath: keptTranscriptPath))
        #expect(!adAnalysisFileStore.documentExists(relativePath: removedAnalysisPath))
        #expect(adAnalysisFileStore.documentExists(relativePath: keptAnalysisPath))
        #expect(appModel.transcriptions.record(for: removedTranscript.episodeID) == nil)
        #expect(appModel.transcriptions.record(for: keptTranscript.episodeID)?.state == .completed)
        #expect(appModel.adAnalyses.record(for: removedTranscript.episodeID) == nil)
        #expect(appModel.adAnalyses.record(for: keptTranscript.episodeID)?.state == .completed)
    }

    @Test("Nuke removes all ad analysis records and sidecars")
    func nukeRemovesAllAdAnalysisRecordsAndSidecars() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: fileStore
        )
        let firstTranscript = makeTranscriptDocument(episodeID: "ad-nuke-1")
        let secondTranscript = makeTranscriptDocument(episodeID: "ad-nuke-2")

        await startAndWait(store: store, transcript: firstTranscript, modelContext: context)
        await startAndWait(store: store, transcript: secondTranscript, modelContext: context)
        #expect(FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))

        try await store.nukeAllAnalyses(modelContext: context)

        #expect(store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))
    }

    @Test("Load marks completed analysis failed when sidecar is missing")
    func loadMarksCompletedAnalysisFailedWhenSidecarIsMissing() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: fileStore
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-missing-sidecar")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let relativePath = try #require(store.record(for: transcript.episodeID)?.analysisRelativePath)
        try fileStore.delete(relativePath: relativePath)

        let reloadedStore = EpisodeAdAnalysisStore(
            client: FakeEpisodeAdAnalysisClient(),
            fileStore: fileStore
        )
        reloadedStore.load(modelContext: context)

        let record = try #require(reloadedStore.record(for: transcript.episodeID))
        #expect(record.state == .failed)
        #expect(record.errorMessage == "Promo/ad analysis document is missing.")
    }

    @Test("Cap rejections thread a typed failure kind onto the record")
    func capRejectionThreadsFailureKindOntoRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = ThrowingEpisodeAdAnalysisClient(error: EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "daily_input_token_cap_exceeded",
            detail: nil
        ))
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-cap-kind")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .capExceeded)
        guard case .failed(let failedRecord, _) = store.jobState(for: transcript) else {
            Issue.record("expected a failed job state")
            return
        }
        #expect(failedRecord.failureKind == .capExceeded)
    }

    @Test("Non-cap failures thread the generic failure kind")
    func nonCapFailuresThreadGenericFailureKind() async throws {
        let errors: [Error] = [
            EpisodeAdAnalysisHTTPError(statusCode: 500, code: "internal", detail: nil),
            EpisodeAdAnalysisHTTPError(statusCode: 429, code: "rate_limited_other", detail: nil)
        ]
        for (index, error) in errors.enumerated() {
            let container = try OpenCastModelContainerFactory.make(inMemory: true)
            let context = ModelContext(container)
            let temporaryDirectory = try makeTemporaryDirectory()
            let store = EpisodeAdAnalysisStore(
                client: ThrowingEpisodeAdAnalysisClient(error: error),
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
            )
            let transcript = makeTranscriptDocument(episodeID: "ad-generic-kind-\(index)")

            store.startAnalysis(transcript: transcript, modelContext: context)

            #expect(await waitUntil {
                store.record(for: transcript.episodeID)?.state == .failed
            })
            let record = try #require(store.record(for: transcript.episodeID))
            #expect(record.failureKind == .generic)
        }
    }

    @Test("A response containing an unknown span kind fails cleanly, never a trusted skip")
    func unknownSpanKindFailsCleanlyInsteadOfTrustedSkip() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = FakeEpisodeAdAnalysisClient()
        client.spanKind = .unknown
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-unknown-kind")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .generic)
        #expect(record.errorMessage == EpisodeAdAnalysisError.unrecognizedSpanKind.localizedDescription)
        #expect(store.document(for: transcript.episodeID) == nil)
    }

    @Test("A successful rerun clears the stored failure kind")
    func successfulRerunClearsFailureKind() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let client = ThrowingEpisodeAdAnalysisClient(error: EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "daily_request_cap_exceeded",
            detail: nil
        ))
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-cap-clears")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })

        client.error = nil
        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == nil)
    }

    #if DEBUG
    @Test("URLSession client posts encoded request and decodes success")
    func urlSessionClientPostsEncodedRequestAndDecodesSuccess() async throws {
        let responseBody = Data("""
        {
          "schema_version": 1,
          "request_id": "client-success",
          "model": "gemini-2.5-flash-lite",
          "policy": "ads_only",
          "spans": [
            {
              "kind": "inserted_ad",
              "label": "Example Sponsor",
              "start_segment_id": 4,
              "end_segment_id": 6,
              "start_time": 10.5,
              "end_time": 21.25,
              "confidence": 0.91,
              "evidence_quote": "sponsor read"
            }
          ],
          "warnings": ["merged adjacent spans"],
          "usage": {
            "prompt_token_count": 123,
            "candidates_token_count": 45,
            "total_token_count": 168
          }
        }
        """.utf8)
        let transport = FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: responseBody)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: transport
        )

        let outcome = try await client.analyze(makeAPIRequest(requestID: "client-success"))
        guard case .completed(let response) = outcome else {
            Issue.record("Expected a synchronous response.")
            return
        }

        let capturedRequest = try #require(transport.lastRequest)
        let capturedBody = try #require(capturedRequest.httpBody)
        let decodedRequest = try JSONDecoder.openCastAdAnalysisTestDecoder.decode(
            EpisodeAdAnalysisAPIRequest.self,
            from: capturedBody
        )
        #expect(capturedRequest.url?.absoluteString == "https://worker.example/v1/ad-analysis/transcript")
        #expect(capturedRequest.value(forHTTPHeaderField: "authorization") == "Bearer test-token")
        #expect(capturedRequest.timeoutInterval == URLSessionEpisodeAdAnalysisClient.analyzeTimeout)
        #expect(decodedRequest.requestID == "client-success")
        #expect(decodedRequest.transcript.state == "completed")
        #expect(response.spans.first?.kind == .insertedAd)
        #expect(response.usage?.totalTokenCount == 168)
    }

    @Test("URLSession client decodes an unknown span kind as .unknown instead of throwing")
    func urlSessionClientDecodesUnknownSpanKind() async throws {
        let responseBody = Data("""
        {
          "schema_version": 1,
          "request_id": "client-unknown-kind",
          "model": "gemini-2.5-flash-lite",
          "policy": "ads_only",
          "spans": [
            {
              "kind": "subliminal_ad",
              "label": "Future Kind",
              "start_segment_id": 4,
              "end_segment_id": 6,
              "start_time": 10.5,
              "end_time": 21.25,
              "confidence": 0.91,
              "evidence_quote": "sponsor read"
            }
          ],
          "warnings": [],
          "usage": null
        }
        """.utf8)
        let transport = FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: responseBody)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: transport
        )

        let outcome = try await client.analyze(makeAPIRequest(requestID: "client-unknown-kind"))
        guard case .completed(let response) = outcome else {
            Issue.record("Expected a synchronous response.")
            return
        }
        #expect(response.spans.first?.kind == .unknown)
    }

    @Test("URLSession bearer client decodes accepted submit and running poll")
    func urlSessionBearerClientDecodesAcceptedSubmitAndRunningPoll() async throws {
        let acceptedTransport = FakeEpisodeAdAnalysisHTTPTransport(
            statusCode: 202,
            body: Data(#"{"job_id":"fingerprint","state":"running","poll_after_seconds":15}"#.utf8)
        )
        let acceptedClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: acceptedTransport
        )

        let submitOutcome = try await acceptedClient.analyze(makeAPIRequest(requestID: "client-accepted"))

        #expect(submitOutcome == .accepted(jobID: "fingerprint", pollAfter: 15))
        #expect(acceptedTransport.lastRequest?.timeoutInterval == URLSessionEpisodeAdAnalysisClient.analyzeTimeout)

        let pollTransport = FakeEpisodeAdAnalysisHTTPTransport(
            statusCode: 202,
            body: Data(#"{"job_id":"fingerprint","state":"running","poll_after_seconds":10}"#.utf8)
        )
        let pollClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: pollTransport
        )

        let pollOutcome = try await pollClient.pollJob(id: "fingerprint")
        let pollRequest = try #require(pollTransport.lastRequest)
        let pollBody = try #require(pollRequest.httpBody)
        let decodedPollBody = try JSONDecoder().decode(EpisodeAdAnalysisJobPollRequest.self, from: pollBody)
        #expect(pollOutcome == .running(pollAfter: 10))
        #expect(pollRequest.url?.path == "/v1/ad-analysis/jobs/fingerprint")
        #expect(pollRequest.timeoutInterval == URLSessionEpisodeAdAnalysisClient.pollTimeout)
        #expect(decodedPollBody == EpisodeAdAnalysisJobPollRequest(jobID: "fingerprint"))
    }

    @Test("URLSession client rejects accepted job ID mismatch")
    func urlSessionClientRejectsAcceptedJobIDMismatch() async {
        let transport = FakeEpisodeAdAnalysisHTTPTransport(
            statusCode: 202,
            body: Data(#"{"job_id":"different-fingerprint","state":"running"}"#.utf8)
        )
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: transport
        )

        await #expect(throws: EpisodeAdAnalysisHTTPError(
            statusCode: -1,
            code: "job_id_mismatch",
            detail: nil
        )) {
            try await client.analyze(makeAPIRequest(requestID: "client-mismatch"))
        }
    }

    @Test("URLSession client decodes structured HTTP errors")
    func urlSessionClientDecodesStructuredHTTPErrors() async throws {
        let errorBody = Data("""
        {
          "error": "body_too_large",
          "detail": "request body exceeds cap"
        }
        """.utf8)
        let transport = FakeEpisodeAdAnalysisHTTPTransport(statusCode: 413, body: errorBody)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: transport
        )

        await #expect(throws: EpisodeAdAnalysisHTTPError(
            statusCode: 413,
            code: "body_too_large",
            detail: "request body exceeds cap"
        )) {
            try await client.analyze(makeAPIRequest(requestID: "client-error"))
        }
    }

    @Test("URLSession client falls back to HTTP status for unstructured errors")
    func urlSessionClientFallsBackToHTTPStatusForUnstructuredErrors() async {
        let transport = FakeEpisodeAdAnalysisHTTPTransport(
            statusCode: 502,
            body: Data("upstream unavailable".utf8)
        )
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .bearer(clientToken: "test-token"),
                isEnabled: true
            ),
            transport: transport
        )

        await #expect(throws: EpisodeAdAnalysisHTTPError(
            statusCode: 502,
            code: "http_502",
            detail: nil
        )) {
            try await client.analyze(makeAPIRequest(requestID: "client-unstructured-error"))
        }
    }
    #endif

    @Test("URLSession App Attest client envelopes request and rotates on recoverable key failure")
    func urlSessionAppAttestClientEnvelopesRequestAndRotatesOnRecoverableKeyFailure() async throws {
        let request = makeAPIRequest(requestID: "client-app-attest")
        let keychainService = "com.connor.opencast.tests.ad-analysis-security.\(UUID().uuidString)"
        let keychain = AppAttestKeychain(service: keychainService)
        try? keychain.deleteAll()
        defer {
            try? keychain.deleteAll()
        }

        let transport = AppAttestRoutingHTTPTransport(analyzeResponses: [
            .error(statusCode: 401, code: "unknown_key"),
            .success(requestID: "client-app-attest")
        ])
        let appAttestService = FakeAppAttestService(
            isSupported: true,
            keyIDs: ["fake-key-1", "fake-key-2"]
        )
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: keychainService),
                isEnabled: true
            ),
            transport: transport,
            appAttestService: appAttestService
        )

        let outcome = try await client.analyze(request)
        guard case .completed(let response) = outcome else {
            Issue.record("Expected a synchronous response.")
            return
        }
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request)
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/transcript",
            payload: payload
        )

        #expect(response.requestID == "client-app-attest")
        #expect(transport.analyzeRequestTimeouts == [
            URLSessionEpisodeAdAnalysisClient.analyzeTimeout,
            URLSessionEpisodeAdAnalysisClient.analyzeTimeout
        ])
        #expect(transport.requestPaths == [
            "/v1/app-attest/challenge",
            "/v1/app-attest/register",
            "/v1/ad-analysis/transcript",
            "/v1/app-attest/challenge",
            "/v1/app-attest/register",
            "/v1/ad-analysis/transcript"
        ])
        #expect(appAttestService.generatedKeys == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.attestationKeyIDs == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.assertionKeyIDs == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.assertionClientDataHashes == [
            AppAttestRequestBinding.hexString(clientDataHash),
            AppAttestRequestBinding.hexString(clientDataHash)
        ])
        #expect(transport.registerRequests.map(\.keyID) == ["fake-key-1", "fake-key-2"])
        #expect(transport.analyzeEnvelopes.map(\.keyID) == ["fake-key-1", "fake-key-2"])
        #expect(transport.analyzeEnvelopes.map(\.payload) == [payload, payload])
        #expect(transport.analyzeEnvelopes.map(\.assertion) == [
            Data("assertion-fake-key-1".utf8).base64EncodedString(),
            Data("assertion-fake-key-2".utf8).base64EncodedString()
        ])
    }

    @Test("URLSession App Attest client binds accepted submit and dynamic poll path")
    func urlSessionAppAttestClientBindsAcceptedSubmitAndDynamicPollPath() async throws {
        let keychainService = "com.connor.opencast.tests.ad-analysis-poll-security.\(UUID().uuidString)"
        let keychain = AppAttestKeychain(service: keychainService)
        try? keychain.deleteAll()
        defer {
            try? keychain.deleteAll()
        }
        let transport = AppAttestRoutingHTTPTransport(
            analyzeResponses: [.accepted(jobID: "fingerprint")],
            pollResponses: [.running(jobID: "fingerprint")]
        )
        let appAttestService = FakeAppAttestService(isSupported: true)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: keychainService),
                isEnabled: true
            ),
            transport: transport,
            appAttestService: appAttestService
        )

        let submitOutcome = try await client.analyze(makeAPIRequest(requestID: "app-attest-accepted"))
        let pollOutcome = try await client.pollJob(id: "fingerprint")
        let pollRequest = EpisodeAdAnalysisJobPollRequest(jobID: "fingerprint")
        let pollPayload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(pollRequest)
        let pollPath = "/v1/ad-analysis/jobs/fingerprint"
        let pollHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: pollPath,
            payload: pollPayload
        )

        #expect(submitOutcome == .accepted(jobID: "fingerprint", pollAfter: 15))
        #expect(pollOutcome == .running(pollAfter: 10))
        #expect(transport.requestPaths == [
            "/v1/app-attest/challenge",
            "/v1/app-attest/register",
            "/v1/ad-analysis/transcript",
            pollPath
        ])
        #expect(transport.analyzeRequestTimeouts == [URLSessionEpisodeAdAnalysisClient.analyzeTimeout])
        #expect(transport.pollRequestTimeouts == [URLSessionEpisodeAdAnalysisClient.pollTimeout])
        #expect(transport.pollEnvelopes.map(\.payload) == [pollPayload])
        #expect(appAttestService.assertionClientDataHashes.last == AppAttestRequestBinding.hexString(pollHash))
    }

    @Test("URLSession client enforces disabled and unsupported App Attest gates")
    func urlSessionClientEnforcesDisabledAndUnsupportedAppAttestGates() async {
        let request = makeAPIRequest(requestID: "client-gates")
        let disabledClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: "test.disabled"),
                isEnabled: false
            ),
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: Data())
        )
        let unsupportedAppAttestClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: "test.unsupported"),
                isEnabled: true
            ),
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: Data()),
            appAttestService: FakeAppAttestService(isSupported: false)
        )

        await #expect(throws: EpisodeAdAnalysisError.clientDisabled) {
            try await disabledClient.analyze(request)
        }
        await #expect(throws: EpisodeAdAnalysisError.appAttestUnavailable) {
            try await unsupportedAppAttestClient.analyze(request)
        }
    }

    @Test("Canonical ad-analysis payload hash matches Worker binding fixture")
    func canonicalAdAnalysisPayloadHashMatchesWorkerBindingFixture() throws {
        let request = makeAPIRequest(requestID: "client-success")
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request)
        let hash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/transcript",
            payload: payload
        )

        #expect(
            payload ==
                #"{"episode_id":"client-episode","episode_title":"Client Episode","podcast_id":"https://example.com/feed.xml","podcast_title":"Client Podcast","request_id":"client-success","schema_version":1,"segments":[{"end":14,"id":4,"start":10.5,"text":"This part is brought to you by Example Sponsor."},{"end":21.25,"id":6,"start":14,"text":"Visit the sponsor for more details."}],"transcript":{"audio_duration":30,"fingerprint":"fingerprint","language_code":"en","model_identifier":"model","model_tree_sha256":"tree-sha","model_version":"v1","segment_count":2,"state":"completed","updated_at":"2026-05-28T20:26:40Z"}}"#
        )
        #expect(AppAttestRequestBinding.sha256Hex(Data(payload.utf8)) == "042cec13b4b71be3ec9b90671fe300c555507b7a04162fb248f4aa8ade69ee4a")
        #expect(AppAttestRequestBinding.hexString(hash) == "e207f0dc7a4a4820ecf959aa727b7c0ecea7aa9d4e8eda2da8dfde45c472eec5")
    }

    @Test("Canonical poll payload hash matches Worker binding fixture")
    func canonicalPollPayloadHashMatchesWorkerBindingFixture() throws {
        let jobID = "fingerprint-123"
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(
            EpisodeAdAnalysisJobPollRequest(jobID: jobID)
        )
        let hash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/jobs/\(jobID)",
            payload: payload
        )

        #expect(payload == #"{"job_id":"fingerprint-123"}"#)
        #expect(AppAttestRequestBinding.sha256Hex(Data(payload.utf8)) == "90da49444d4246a08405079cd75a63c2649a45850ceb8de7e00e2a78eb29a471")
        #expect(AppAttestRequestBinding.hexString(hash) == "c079e99784a3722a3b90e2523920fcca7c99a429ec3ad37e192acc8a87458d0a")
    }

    private func makeAPIRequest(requestID: String) -> EpisodeAdAnalysisAPIRequest {
        EpisodeAdAnalysisAPIRequest(
            schemaVersion: 1,
            requestID: requestID,
            episodeID: "client-episode",
            podcastID: "https://example.com/feed.xml",
            episodeTitle: "Client Episode",
            podcastTitle: "Client Podcast",
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: "en",
                audioDuration: 30,
                modelIdentifier: "model",
                modelVersion: "v1",
                modelTreeSHA256: "tree-sha",
                fingerprint: "fingerprint",
                updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                state: "completed",
                segmentCount: 2
            ),
            segments: [
                EpisodeAdAnalysisAPISegment(
                    id: 4,
                    start: 10.5,
                    end: 14,
                    text: "This part is brought to you by Example Sponsor."
                ),
                EpisodeAdAnalysisAPISegment(
                    id: 6,
                    start: 14,
                    end: 21.25,
                    text: "Visit the sponsor for more details."
                )
            ]
        )
    }

    private func encodedJSONString(_ request: EpisodeAdAnalysisAPIRequest) throws -> String {
        let data = try JSONEncoder.openCastAdAnalysisTestEncoder.encode(request)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeTranscript(
        _ document: EpisodeTranscriptDocument,
        fileStore: EpisodeTranscriptFileStore,
        modelContext: ModelContext,
        state: EpisodeTranscriptState = .completed
    ) throws -> String {
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: document.episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        modelContext.insert(EpisodeTranscriptRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL: document.sourceAudioURL,
            sourceFileByteCount: document.sourceFileByteCount,
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256,
            languageCode: document.languageCode,
            state: state,
            audioDuration: document.audioDuration,
            completedDuration: document.audioDuration,
            checkpointCount: document.checkpoints.count,
            transcriptRelativePath: relativePath,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        ))
        try modelContext.save()
        return relativePath
    }

    private func makeTranscriptDocument(
        episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        sponsorSegmentText: String = "This episode is brought to you by Example Sponsor.",
        extraSegmentText: String? = nil
    ) -> EpisodeTranscriptDocument {
        var segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 5,
                text: "Welcome back to the show.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 5,
                end: 12,
                text: sponsorSegmentText,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        if let extraSegmentText {
            segments.append(OpenCastTranscriptSegment(
                id: 2,
                start: 12,
                end: 16,
                text: extraSegmentText,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ))
        }

        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 987_654_321,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 16,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdAnalysisTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func startAndWait(
        store: EpisodeAdAnalysisStore,
        transcript: EpisodeTranscriptDocument,
        modelContext: ModelContext
    ) async {
        store.startAnalysis(transcript: transcript, modelContext: modelContext)
        #expect(await waitUntil {
            !store.hasActiveJob
                && store.record(for: transcript.episodeID)?.state == .completed
        })
    }
}


private final class ThrowingEpisodeAdAnalysisClient: EpisodeAdAnalysisClient, @unchecked Sendable {
    var error: Error?

    init(error: Error?) {
        self.error = error
    }

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        if let error {
            throw error
        }

        return .completed(EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [],
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}

private final class FakeEpisodeAdAnalysisClient: EpisodeAdAnalysisClient, @unchecked Sendable {
    var lastRequest: EpisodeAdAnalysisAPIRequest?
    var spanKind: EpisodeAdAnalysisSpanKind = .hostReadAd

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        lastRequest = request
        return .completed(EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisAPIAdSpan(
                    kind: spanKind,
                    label: "Example Sponsor",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 5,
                    endTime: 12,
                    confidence: 0.96,
                    evidenceQuote: "brought to you"
                )
            ],
            warnings: [],
            usage: EpisodeAdAnalysisAPIUsage(
                promptTokenCount: 100,
                candidatesTokenCount: 20,
                totalTokenCount: 120
            )
        ))
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}

private final class FakeEpisodeAdAnalysisHTTPTransport: EpisodeAdAnalysisHTTPTransport, AppAttestHTTPTransport, @unchecked Sendable {
    private let statusCode: Int
    private let body: Data
    private(set) var lastRequest: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (body, response)
    }
}

private final class AppAttestRoutingHTTPTransport: EpisodeAdAnalysisHTTPTransport, AppAttestHTTPTransport, @unchecked Sendable {
    private var analyzeResponses: [AnalyzeResponse]
    private var pollResponses: [AnalyzeResponse]
    private var challengeCount = 0
    private(set) var requestPaths: [String] = []
    private(set) var registerRequests: [CapturedAppAttestRegisterRequest] = []
    private(set) var analyzeEnvelopes: [CapturedAppAttestEnvelope] = []
    private(set) var analyzeRequestTimeouts: [TimeInterval] = []
    private(set) var pollEnvelopes: [CapturedAppAttestEnvelope] = []
    private(set) var pollRequestTimeouts: [TimeInterval] = []

    init(analyzeResponses: [AnalyzeResponse], pollResponses: [AnalyzeResponse] = []) {
        self.analyzeResponses = analyzeResponses
        self.pollResponses = pollResponses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        requestPaths.append(path)

        let response: (statusCode: Int, body: Data)
        switch path {
        case "/v1/app-attest/challenge":
            challengeCount += 1
            response = (
                200,
                Data("""
                {
                  "challenge_id": "challenge-\(challengeCount)",
                  "challenge": "challenge-value-\(challengeCount)"
                }
                """.utf8)
            )
        case "/v1/app-attest/register":
            let body = try #require(request.httpBody)
            registerRequests.append(try JSONDecoder().decode(
                CapturedAppAttestRegisterRequest.self,
                from: body
            ))
            response = (200, Data(#"{"message":"registered"}"#.utf8))
        case "/v1/ad-analysis/transcript":
            let body = try #require(request.httpBody)
            analyzeRequestTimeouts.append(request.timeoutInterval)
            analyzeEnvelopes.append(try JSONDecoder().decode(
                CapturedAppAttestEnvelope.self,
                from: body
            ))
            response = try #require(analyzeResponses.isEmpty ? nil : analyzeResponses.removeFirst().httpResponse)
        case let path where path.hasPrefix("/v1/ad-analysis/jobs/"):
            let body = try #require(request.httpBody)
            pollRequestTimeouts.append(request.timeoutInterval)
            pollEnvelopes.append(try JSONDecoder().decode(
                CapturedAppAttestEnvelope.self,
                from: body
            ))
            response = try #require(pollResponses.isEmpty ? nil : pollResponses.removeFirst().httpResponse)
        default:
            response = (404, Data(#"{"error":"not_found"}"#.utf8))
        }

        let urlResponse = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (response.body, urlResponse)
    }
}

private enum AnalyzeResponse {
    case success(requestID: String)
    case accepted(jobID: String)
    case running(jobID: String)
    case error(statusCode: Int, code: String)

    var httpResponse: (statusCode: Int, body: Data) {
        switch self {
        case .success(let requestID):
            return (
                200,
                Data("""
                {
                  "schema_version": 1,
                  "request_id": "\(requestID)",
                  "model": "gemini-2.5-flash-lite",
                  "policy": "ads_only",
                  "spans": [],
                  "warnings": [],
                  "usage": null
                }
                """.utf8)
            )
        case .accepted(let jobID):
            return (
                202,
                Data(#"{"job_id":"\#(jobID)","state":"running","poll_after_seconds":15}"#.utf8)
            )
        case .running(let jobID):
            return (
                202,
                Data(#"{"job_id":"\#(jobID)","state":"running","poll_after_seconds":10}"#.utf8)
            )
        case .error(let statusCode, let code):
            return (statusCode, Data(#"{"error":"\#(code)"}"#.utf8))
        }
    }
}

private struct CapturedAppAttestRegisterRequest: Decodable {
    let installID: String
    let keyID: String
    let challengeID: String
    let challenge: String
    let attestationObject: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case challenge
        case attestationObject = "attestation_object"
    }
}

private struct CapturedAppAttestEnvelope: Decodable {
    let installID: String
    let keyID: String
    let payload: String
    let assertion: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case payload
        case assertion
    }
}

private final class FakeAppAttestService: AppAttestServiceProtocol, @unchecked Sendable {
    let isSupported: Bool
    private let keyIDs: [String]
    private var nextKeyIndex = 0
    private(set) var generatedKeys: [String] = []
    private(set) var attestationKeyIDs: [String] = []
    private(set) var attestationClientDataHashes: [String] = []
    private(set) var assertionKeyIDs: [String] = []
    private(set) var assertionClientDataHashes: [String] = []

    init(isSupported: Bool, keyIDs: [String] = ["fake-key"]) {
        self.isSupported = isSupported
        self.keyIDs = keyIDs
    }

    func generateKey() async throws -> String {
        let keyID = keyIDs[min(nextKeyIndex, keyIDs.count - 1)]
        nextKeyIndex += 1
        generatedKeys.append(keyID)
        return keyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationKeyIDs.append(keyID)
        attestationClientDataHashes.append(AppAttestRequestBinding.hexString(clientDataHash))
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionKeyIDs.append(keyID)
        assertionClientDataHashes.append(AppAttestRequestBinding.hexString(clientDataHash))
        return Data("assertion-\(keyID)".utf8)
    }
}

private actor HangingEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    private(set) var requestCount = 0
    private var shouldRelease = false

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        requestCount += 1
        while !shouldRelease {
            try await Task.sleep(for: .milliseconds(10))
            try Task.checkCancellation()
        }
        return .completed(EpisodeAdAnalysisAPIResponse(
            schemaVersion: request.schemaVersion,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisAPIAdSpan(
                    kind: .hostReadAd,
                    label: "Example Sponsor",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 5,
                    endTime: 12,
                    confidence: 0.96,
                    evidenceQuote: "brought to you"
                )
            ],
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }

    func waitForRequest() async -> Bool {
        for _ in 0..<100 {
            if requestCount > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return requestCount > 0
    }

    func currentRequestCount() -> Int {
        requestCount
    }

    func release() {
        shouldRelease = true
    }
}

private extension JSONEncoder {
    static var openCastAdAnalysisTestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var openCastAdAnalysisTestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
