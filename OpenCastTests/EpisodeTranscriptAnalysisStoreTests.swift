import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcript analysis store")
struct EpisodeTranscriptAnalysisStoreTests {
    @Test("Creates analysis record and document from client response")
    func createsRecordAndDocumentFromClientResponse() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = FakeEpisodeTranscriptAnalysisClient()
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-create")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let request = try #require(client.lastRequest)
        let encodedRequest = String(
            decoding: try EpisodeTranscriptAnalysisJSONCoding.encoder().encode(request),
            as: UTF8.self
        )
        #expect(record.chapterCount == 2)
        #expect(record.policy == "transcript_analysis_v2")
        #expect(document.chapters.map(\.title) == ["Welcome", "The Sponsor Read"])
        #expect(document.chapters[1].startSegmentID == 1)
        #expect(document.summary?.oneLineDescription == "A short test episode")
        #expect(document.summary?.claims.first?.evidenceSegmentID == 0)
        #expect(document.transcriptSegmentCount == transcript.segments.count)
        // H2: real titles are on the wire — a nil title would change prompt
        // bytes and void the request validation.
        #expect(request.episodeTitle == "Episode Title")
        #expect(request.podcastTitle == "Podcast Title")
        #expect(encodedRequest.contains(#""episode_title":"Episode Title""#))
        // Sharing ships dark — every request declares it off.
        #expect(request.allowShared == false)
        #expect(encodedRequest.contains(#""allow_shared":false"#))
        #expect(encodedRequest.contains(#""async_supported":true"#))
        #expect(!encodedRequest.contains(transcript.sourceAudioURL))
        #expect(!encodedRequest.contains(transcript.sourceFileSHA256))
    }

    @Test("Cap rejections thread the capExceeded kind and surface as deferred")
    func capRejectionsThreadCapExceededAndDefer() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = ThrowingEpisodeTranscriptAnalysisClient(
            error: EpisodeTranscriptAnalysisHTTPError(
                statusCode: 429,
                code: "daily_request_cap_exceeded",
                detail: nil
            )
        )
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-cap")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .capExceeded)
        #expect(store.capDeferredEpisodeIDs == [transcript.episodeID])
    }

    @Test("Insufficient-seconds 402s thread the insufficientSeconds kind and defer for a balance increase")
    func insufficientSeconds402ThreadsKindAndDefers() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = ThrowingEpisodeTranscriptAnalysisClient(
            error: EpisodeTranscriptAnalysisHTTPError(
                statusCode: 402,
                code: "insufficient_transcription_seconds",
                detail: nil
            )
        )
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-402")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .insufficientSeconds)
        #expect(store.insufficientSecondsDeferredEpisodeIDs == [transcript.episodeID])
        #expect(store.capDeferredEpisodeIDs.isEmpty)
    }

    @Test("A defensive async_required 400 stays a generic quiet failure")
    func asyncRequiredStaysGenericQuietFailure() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = ThrowingEpisodeTranscriptAnalysisClient(
            error: EpisodeTranscriptAnalysisHTTPError(
                statusCode: 400,
                code: "async_required",
                detail: nil
            )
        )
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-async-required")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .generic)
        #expect(store.insufficientSecondsDeferredEpisodeIDs.isEmpty)
        #expect(store.capDeferredEpisodeIDs.isEmpty)
    }

    @Test("A bootstrap_required 403 repairs the account link and retries once")
    func bootstrapRequiredRepairsLinkAndRetries() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = BootstrapRepairingEpisodeTranscriptAnalysisClient()
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-bootstrap")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        // The 403 is repaired transparently: bootstrap between the two
        // analyze calls, no failure surfaced anywhere.
        #expect(client.events == ["analyze", "bootstrap", "analyze"])
        #expect(store.lastErrorMessage(for: transcript.episodeID) == nil)
    }

    @Test("Generic failures never join the cap-deferred retry set")
    func genericFailuresAreNotCapDeferred() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = ThrowingEpisodeTranscriptAnalysisClient(
            error: EpisodeTranscriptAnalysisHTTPError(
                statusCode: 502,
                code: "model_output_truncated",
                detail: nil
            )
        )
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-502")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .generic)
        #expect(store.capDeferredEpisodeIDs.isEmpty)
        #expect(store.document(for: transcript.episodeID) == nil)
    }

    @Test("A response from an unexpected policy fails cleanly")
    func unexpectedPolicyResponseFailsCleanly() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = FakeEpisodeTranscriptAnalysisClient()
        client.policy = "transcript_analysis_v999"
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-policy")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .generic)
        #expect(store.document(for: transcript.episodeID) == nil)
    }

    @Test("A completed analysis with no chapters and no summary is never current")
    func contentlessCompletedAnalysisIsNeverCurrent() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        // The throwing client's success path returns a completed response
        // with zero chapters and no summary.
        let client = ThrowingEpisodeTranscriptAnalysisClient(error: nil)
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-contentless")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: transcript.episodeID))
        #expect(!document.hasPresentableContent)

        // Rendering neither card while also reporting "current" would hide
        // Generate permanently; the empty result must not count as current
        // for the detail surface or for the auto-run/explicit skip check.
        let state = await store.episodeDetailState(
            for: transcript,
            transcriptState: .completed,
            analysisDocument: document
        )
        #expect(!state.hasCurrentCompletedAnalysis)
        guard case .completed(_, let isStale) = state.jobState else {
            Issue.record("Expected a completed job state, got \(state.jobState)")
            return
        }
        #expect(!isStale)
        #expect(await !store.hasCurrentCompletedAnalysis(for: transcript))
    }

    @Test("Completed analysis is stale once the transcript changes")
    func completedAnalysisIsStaleOnceTranscriptChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let client = FakeEpisodeTranscriptAnalysisClient()
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "chapters-stale")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })

        guard case .completed(_, let freshIsStale) = store.jobState(for: transcript) else {
            Issue.record("Expected a completed job state for the unchanged transcript")
            return
        }
        #expect(!freshIsStale)

        var changedTranscript = transcript
        changedTranscript.segments[1].text += " (remastered)"
        changedTranscript.text = changedTranscript.segments.map(\.text).joined(separator: " ")
        guard case .completed(_, let changedIsStale) = store.jobState(for: changedTranscript) else {
            Issue.record("Expected a completed job state for the changed transcript")
            return
        }
        #expect(changedIsStale)
    }

    @Test("An active job never marks other episodes as running")
    func activeJobNeverMarksOtherEpisodesRunning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = SuspensionGate()
        let client = GatedEpisodeTranscriptAnalysisClient(gate: gate)
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let runningTranscript = makeTranscriptDocument(episodeID: "chapters-running-a")
        let otherTranscript = makeTranscriptDocument(episodeID: "chapters-idle-b")

        store.startAnalysis(
            transcript: runningTranscript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(store.isRunning(for: runningTranscript.episodeID))

        // Episode B was never queued: while A's job is in flight it must
        // offer Generate, not report A's run as its own. (The detail view
        // invalidates on its own episode's isRunning flag, so a borrowed
        // running state would outlive A's job.)
        guard case .running = store.jobState(for: runningTranscript) else {
            Issue.record("Expected the active episode to report running")
            return
        }
        #expect(!store.isRunning(for: otherTranscript.episodeID))
        guard case .ready = store.jobState(for: otherTranscript) else {
            Issue.record("Expected the uninvolved episode to stay ready, got \(store.jobState(for: otherTranscript))")
            return
        }

        await gate.open()
        #expect(await waitUntil { !store.hasActiveJob })
    }

    @Test("Transcript analysis record is local-only but included in full schema")
    func transcriptAnalysisRecordIsLocalOnly() {
        let localEntityNames = OpenCastModelContainerFactory.localSchema.entities.map(\.name)
        let syncedEntityNames = OpenCastModelContainerFactory.syncedSchema.entities.map(\.name)
        let fullEntityNames = OpenCastModelContainerFactory.fullSchema.entities.map(\.name)
        #expect(localEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
        #expect(!syncedEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
        #expect(fullEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
    }

    @Test("Duplicate repair OR-merges the opt-in onto the deterministic winner")
    func duplicateRepairORMergesOptIn() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/chapters-merge.xml"

        // The winner (smallest dedupeUUID) has the flag OFF; a losing twin
        // carries the explicit opt-in. The merge must keep the winner row and
        // the consent.
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Winner Copy",
                isTranscriptAnalysisEnabled: false,
                dedupeUUID: "aaaaaaaa-0000-0000-0000-000000000000"
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Loser Copy",
                isTranscriptAnalysisEnabled: true,
                dedupeUUID: "bbbbbbbb-0000-0000-0000-000000000000"
            )
        )
        try context.save()

        _ = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        let survivor = try #require(subscriptions.first)
        #expect(survivor.dedupeUUID == "aaaaaaaa-0000-0000-0000-000000000000")
        #expect(survivor.isTranscriptAnalysisEnabled == true)
    }

    @Test("Legacy duplicate replacement carries the opt-in onto the fresh record")
    func legacyDuplicateReplacementCarriesOptIn() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/chapters-legacy-merge.xml"

        context.insert(
            SubscriptionRecord(feedURL: feedURL, title: "Legacy Off", isTranscriptAnalysisEnabled: false, dedupeUUID: "")
        )
        context.insert(
            SubscriptionRecord(feedURL: feedURL, title: "Legacy On", isTranscriptAnalysisEnabled: true, dedupeUUID: "")
        )
        try context.save()

        _ = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        let survivor = try #require(subscriptions.first)
        #expect(!survivor.dedupeUUID.isEmpty)
        #expect(survivor.isTranscriptAnalysisEnabled == true)
    }

    @Test("Generate disclosure copy composes from the feature flags")
    func generateDisclosureCopyComposesFromFlags() {
        // All flags live pins the full first-tap disclosure byte-for-byte.
        let pinnedBody = """
        This episode’s transcript is sent to OpenCast to generate chapters and a summary. Your audio is never sent.
        Results are saved on this device.
        Chapters may be shared with other listeners of the same episode.
        Uses transcription minutes.
        """
        #expect(
            TranscriptAnalysisGenerateDisclosureCopy.confirmationBody(
                isSharingEnabled: true,
                chargesTranscriptionMinutes: true
            ) == pinnedBody
        )

        // Both features dark composes down to the base disclosure alone.
        let darkBody = TranscriptAnalysisGenerateDisclosureCopy.confirmationBody(
            isSharingEnabled: false,
            chargesTranscriptionMinutes: false
        )
        #expect(!darkBody.contains("shared"))
        #expect(!darkBody.contains("transcription minutes"))
        #expect(darkBody == """
        This episode’s transcript is sent to OpenCast to generate chapters and a summary. Your audio is never sent.
        Results are saved on this device.
        """)

        // Shipping flags: the pay gate is lit, sharing stays dark — the
        // minutes sentence appears, the sharing sentence must not.
        let shippingBody = TranscriptAnalysisGenerateDisclosureCopy.confirmationBody()
        #expect(!shippingBody.contains("shared"))
        #expect(shippingBody == """
        This episode’s transcript is sent to OpenCast to generate chapters and a summary. Your audio is never sent.
        Results are saved on this device.
        Uses transcription minutes.
        """)
        #expect(TranscriptAnalysisGenerateDisclosureCopy.title == "Generate Chapters & Summary?")
        #expect(TranscriptAnalysisGenerateDisclosureCopy.confirmButtonTitle == "Generate")
    }

    @Test("Cap retry probe drains past ineligible deferrals and stale cap records never starve the queue")
    func capRetryProbeDrainsPastIneligibleDeferralsAndStaleCapRecordsDoNotStarve() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let client = FakeEpisodeTranscriptAnalysisClient()
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )

        // One deferral belongs to an episode that was never transcribed —
        // the eligibility gate skips it. The transcribed show has an episode
        // with creator chapters (the gate skips it too, without touching its
        // record) ahead of a plain episode the worker now admits.
        let untranscribedSnapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Untranscribed Show</title>
                    <item>
                      <title>Untranscribed Episode</title>
                      <guid>cap-optout-1</guid>
                      <enclosure url="https://example.com/audio/cap-optout-1.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/cap-optout.xml")!
        )
        let transcribedSnapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Transcribed Show</title>
                    <item>
                      <title>Creator Chaptered</title>
                      <guid>cap-optin-chaptered</guid>
                      <podcast:chapters url="https://example.com/chapters/cap-optin.json" type="application/json+chapters" />
                      <enclosure url="https://example.com/audio/cap-optin-chaptered.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Plain</title>
                      <guid>cap-optin-plain</guid>
                      <enclosure url="https://example.com/audio/cap-optin-plain.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/cap-optin.xml")!
        )
        try await localCache.upsertCache(from: untranscribedSnapshot, refreshedAt: .now)
        try await localCache.upsertCache(from: transcribedSnapshot, refreshedAt: .now)

        let untranscribedFeedURL = untranscribedSnapshot.podcast.id.rawValue
        let transcribedFeedURL = transcribedSnapshot.podcast.id.rawValue
        let untranscribedEpisodeID = untranscribedSnapshot.episodes[0].id.rawValue
        let chapteredEpisodeID = transcribedSnapshot.episodes[0].id.rawValue
        let plainEpisodeID = transcribedSnapshot.episodes[1].id.rawValue
        context.insert(SubscriptionRecord(feedURL: untranscribedFeedURL, title: "Untranscribed Show"))
        context.insert(SubscriptionRecord(feedURL: transcribedFeedURL, title: "Transcribed Show"))
        for episodeID in [chapteredEpisodeID, plainEpisodeID] {
            try seedCompletedTranscript(
                episodeID: episodeID,
                podcastID: transcribedFeedURL,
                fileStore: transcriptFileStore,
                context: context
            )
        }
        // All three carry cap denials from an earlier session; updatedAt
        // ordering drains both gate-skipped episodes before the runnable one.
        let base = Date(timeIntervalSince1970: 1_780_100_000)
        insertCapDeferredRecord(
            episodeID: untranscribedEpisodeID,
            podcastID: untranscribedFeedURL,
            updatedAt: base.addingTimeInterval(20),
            context: context
        )
        insertCapDeferredRecord(
            episodeID: chapteredEpisodeID,
            podcastID: transcribedFeedURL,
            updatedAt: base.addingTimeInterval(10),
            context: context
        )
        insertCapDeferredRecord(
            episodeID: plainEpisodeID,
            podcastID: transcribedFeedURL,
            updatedAt: base,
            context: context
        )
        try context.save()

        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        // The deferrals model manually started runs, so consent is on file.
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)

        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: .sceneActivated)

        #expect(await waitUntil {
            transcriptAnalyses.record(for: plainEpisodeID)?.state == .completed
                && !transcriptAnalyses.hasActiveJob
        })
        // Only the runnable episode reached the worker: the untranscribed
        // and creator-chaptered deferrals skipped on the eligibility gate,
        // and the stale capExceeded left on both skipped records did not
        // halt the drain behind them.
        #expect(client.requests.map(\.episodeID) == [plainEpisodeID])
        #expect(transcriptAnalyses.record(for: untranscribedEpisodeID)?.failureKind == .capExceeded)
        #expect(transcriptAnalyses.record(for: chapteredEpisodeID)?.failureKind == .capExceeded)
    }

    @Test("Balance increase sweeps only insufficient-seconds deferrals; the probe stays intact")
    func balanceIncreaseSweepsOnlyInsufficientDeferrals() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let client = FakeEpisodeTranscriptAnalysisClient()
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )

        let transcribedSnapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Balance Transcribed Show</title>
                    <item>
                      <title>Needs Minutes</title>
                      <guid>balance-optin-needs</guid>
                      <enclosure url="https://example.com/audio/balance-optin-needs.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Cap Deferred</title>
                      <guid>balance-optin-cap</guid>
                      <enclosure url="https://example.com/audio/balance-optin-cap.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/balance-optin.xml")!
        )
        let untranscribedSnapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Balance Untranscribed Show</title>
                    <item>
                      <title>Untranscribed Needs Minutes</title>
                      <guid>balance-optout-needs</guid>
                      <enclosure url="https://example.com/audio/balance-optout-needs.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/balance-optout.xml")!
        )
        try await localCache.upsertCache(from: transcribedSnapshot, refreshedAt: .now)
        try await localCache.upsertCache(from: untranscribedSnapshot, refreshedAt: .now)

        let transcribedFeedURL = transcribedSnapshot.podcast.id.rawValue
        let untranscribedFeedURL = untranscribedSnapshot.podcast.id.rawValue
        let needsMinutesEpisodeID = transcribedSnapshot.episodes[0].id.rawValue
        let capEpisodeID = transcribedSnapshot.episodes[1].id.rawValue
        let untranscribedEpisodeID = untranscribedSnapshot.episodes[0].id.rawValue
        context.insert(SubscriptionRecord(feedURL: transcribedFeedURL, title: "Balance Transcribed Show"))
        context.insert(SubscriptionRecord(feedURL: untranscribedFeedURL, title: "Balance Untranscribed Show"))
        for episodeID in [needsMinutesEpisodeID, capEpisodeID] {
            try seedCompletedTranscript(
                episodeID: episodeID,
                podcastID: transcribedFeedURL,
                fileStore: transcriptFileStore,
                context: context
            )
        }
        let base = Date(timeIntervalSince1970: 1_780_200_000)
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: needsMinutesEpisodeID,
            podcastID: transcribedFeedURL,
            updatedAt: base.addingTimeInterval(20),
            context: context
        )
        insertDeferredRecord(
            kind: .capExceeded,
            episodeID: capEpisodeID,
            podcastID: transcribedFeedURL,
            updatedAt: base.addingTimeInterval(10),
            context: context
        )
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: untranscribedEpisodeID,
            podcastID: untranscribedFeedURL,
            updatedAt: base,
            context: context
        )
        try context.save()

        let (purchases, _) = makeBalancePurchaseStore()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            remoteTranscriptionPurchases: purchases,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        // The deferrals model manually started runs, so consent is on file.
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)
        // The increase applied a balance that covers the 35 s estimate.
        #expect(await purchases.refreshBalance())
        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: .balanceIncreased)

        #expect(await waitUntil {
            transcriptAnalyses.record(for: needsMinutesEpisodeID)?.state == .completed
                && !transcriptAnalyses.hasActiveJob
        })
        // Only the transcribed pay-gate deferral ran: the cap deferral stays
        // parked (credit can't clear a cap) and the untranscribed one skips
        // on the eligibility gate without touching its record.
        #expect(client.requests.map(\.episodeID) == [needsMinutesEpisodeID])
        #expect(transcriptAnalyses.record(for: capEpisodeID)?.failureKind == .capExceeded)
        #expect(transcriptAnalyses.record(for: untranscribedEpisodeID)?.failureKind == .insufficientSeconds)

        // The balance sweep must not spend the foreground session's one
        // scene-activation probe: the cap deferral still re-probes.
        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: .sceneActivated)
        #expect(await waitUntil {
            transcriptAnalyses.record(for: capEpisodeID)?.state == .completed
                && !transcriptAnalyses.hasActiveJob
        })
        #expect(client.requests.map(\.episodeID) == [needsMinutesEpisodeID, capEpisodeID])
    }

    @Test("A fresh insufficient-seconds denial halts the drain instead of uploading every queued retry")
    func freshInsufficientDenialHaltsDrain() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let client = ThrowingEpisodeTranscriptAnalysisClient(
            error: EpisodeTranscriptAnalysisHTTPError(
                statusCode: 402,
                code: "insufficient_transcription_seconds",
                detail: nil
            )
        )
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )

        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Broke Show</title>
                    <item>
                      <title>First Long Episode</title>
                      <guid>halt-402-first</guid>
                      <enclosure url="https://example.com/audio/halt-402-first.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Second Long Episode</title>
                      <guid>halt-402-second</guid>
                      <enclosure url="https://example.com/audio/halt-402-second.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/halt-402.xml")!
        )
        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        let feedURL = snapshot.podcast.id.rawValue
        let firstEpisodeID = snapshot.episodes[0].id.rawValue
        let secondEpisodeID = snapshot.episodes[1].id.rawValue
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Broke Show"))
        for episodeID in [firstEpisodeID, secondEpisodeID] {
            try seedCompletedTranscript(
                episodeID: episodeID,
                podcastID: feedURL,
                fileStore: transcriptFileStore,
                context: context
            )
        }
        let base = Date(timeIntervalSince1970: 1_780_300_000)
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: firstEpisodeID,
            podcastID: feedURL,
            updatedAt: base.addingTimeInterval(10),
            context: context
        )
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: secondEpisodeID,
            podcastID: feedURL,
            updatedAt: base,
            context: context
        )
        try context.save()

        // The refreshed balance covers both estimates, so the launch sweep
        // queues both; the worker, which stays authoritative, refuses.
        let (purchases, _) = makeBalancePurchaseStore()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            remoteTranscriptionPurchases: purchases,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        // The deferrals model manually started runs, so consent is on file.
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)
        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: .launch)

        // The first run's FRESH 402 must stop the drain: each further queued
        // retry would cost a reserve call and a full transcript upload.
        #expect(await waitUntil {
            client.analyzeCallCount == 1 && !transcriptAnalyses.hasActiveJob
        })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.analyzeCallCount == 1)
        #expect(transcriptAnalyses.record(for: firstEpisodeID)?.failureKind == .insufficientSeconds)
        #expect(transcriptAnalyses.record(for: secondEpisodeID)?.failureKind == .insufficientSeconds)
        #expect(
            Set(transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs)
                == [firstEpisodeID, secondEpisodeID]
        )
    }

    @Test("Deferrals inherited before the disclosure acknowledgement demote and never re-upload")
    func preConsentDeferralsDemoteInsteadOfRetrying() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let client = FakeEpisodeTranscriptAnalysisClient()
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )

        // A previous-version install upgrading to manual generation: the
        // retired auto-run left typed deferrals behind for fully eligible
        // episodes (its per-show opt-in may have been withdrawn before the
        // upgrade), and the generate disclosure has never been acknowledged.
        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Legacy Consent Show</title>
                    <item>
                      <title>Cap Deferred</title>
                      <guid>legacy-consent-cap</guid>
                      <enclosure url="https://example.com/audio/legacy-consent-cap.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Needs Minutes</title>
                      <guid>legacy-consent-needs</guid>
                      <enclosure url="https://example.com/audio/legacy-consent-needs.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/legacy-consent.xml")!
        )
        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        let feedURL = snapshot.podcast.id.rawValue
        let capEpisodeID = snapshot.episodes[0].id.rawValue
        let needsMinutesEpisodeID = snapshot.episodes[1].id.rawValue
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Legacy Consent Show"))
        for episodeID in [capEpisodeID, needsMinutesEpisodeID] {
            try seedCompletedTranscript(
                episodeID: episodeID,
                podcastID: feedURL,
                fileStore: transcriptFileStore,
                context: context
            )
        }
        let base = Date(timeIntervalSince1970: 1_780_400_000)
        insertDeferredRecord(
            kind: .capExceeded,
            episodeID: capEpisodeID,
            podcastID: feedURL,
            updatedAt: base.addingTimeInterval(10),
            context: context
        )
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: needsMinutesEpisodeID,
            podcastID: feedURL,
            updatedAt: base,
            context: context
        )
        try context.save()

        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)
        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: .launch)

        // The load demoted both inherited deferrals to plain failures, so
        // the launch sweep found nothing to re-upload.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.requests.isEmpty)
        #expect(!transcriptAnalyses.hasAcknowledgedGenerateDisclosure)
        #expect(transcriptAnalyses.capDeferredEpisodeIDs.isEmpty)
        #expect(transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs.isEmpty)
        for episodeID in [capEpisodeID, needsMinutesEpisodeID] {
            let record = try #require(transcriptAnalyses.record(for: episodeID))
            #expect(record.state == .failed)
            #expect(record.failureKind == .generic)
        }
    }

    @Test("The disclosure acknowledgement persists across loads and keeps manual deferrals retryable")
    func acknowledgementPersistsAcrossLoads() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = EpisodeTranscriptAnalysisStore(
            client: FakeEpisodeTranscriptAnalysisClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        #expect(!store.hasAcknowledgedGenerateDisclosure)
        store.acknowledgeGenerateDisclosure(modelContext: context)
        #expect(store.hasAcknowledgedGenerateDisclosure)
        insertDeferredRecord(
            kind: .insufficientSeconds,
            episodeID: "consent-kept",
            podcastID: "https://example.com/consent-kept.xml",
            updatedAt: .now,
            context: context
        )
        try context.save()

        let reloadedStore = EpisodeTranscriptAnalysisStore(
            client: FakeEpisodeTranscriptAnalysisClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        reloadedStore.load(modelContext: context)

        #expect(reloadedStore.hasAcknowledgedGenerateDisclosure)
        #expect(reloadedStore.record(for: "consent-kept")?.failureKind == .insufficientSeconds)
        #expect(reloadedStore.insufficientSecondsDeferredEpisodeIDs == ["consent-kept"])
    }

    @Test("Episode detail snapshot threads the creator chapters URL")
    func episodeDetailSnapshotThreadsChaptersURL() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let feedURL = URL(string: "https://example.com/chaptered-cache.xml")!
        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Chaptered Cache Show</title>
                    <item>
                      <title>With Chapters</title>
                      <guid>cache-chaptered-1</guid>
                      <podcast:chapters url="https://example.com/chapters/cache-1.json" type="application/json+chapters" />
                      <enclosure url="https://example.com/audio/cache-1.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Without Chapters</title>
                      <guid>cache-chaptered-2</guid>
                      <enclosure url="https://example.com/audio/cache-2.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: feedURL
        )
        try await cache.upsertCache(from: snapshot, refreshedAt: .now)

        let chaptered = try #require(
            await cache.episodeDetail(episodeID: snapshot.episodes[0].id.rawValue)
        )
        #expect(chaptered.chaptersURL == "https://example.com/chapters/cache-1.json")
        let plain = try #require(
            await cache.episodeDetail(episodeID: snapshot.episodes[1].id.rawValue)
        )
        #expect(plain.chaptersURL == nil)
    }

    // MARK: - Credit-deferral sweep policy

    @Test("A cold launch submits a credit deferral once: the launch sweep consumes the foreground probe")
    func coldLaunchSubmitsCreditDeferralOnce() async throws {
        let client = ThrowingEpisodeTranscriptAnalysisClient(error: Self.insufficientSecondsError)
        let harness = try await makeDeferredQueueHarness(
            slug: "cold-launch",
            episodes: [DeferredEpisodeSpec(kind: .insufficientSeconds)],
            client: client
        )
        harness.loadAnalysisStore()
        harness.retry(.launch)

        #expect(await waitUntil {
            client.analyzeCallCount == 1 && !harness.transcriptAnalyses.hasActiveJob
        })
        // Scene activation lands after the store load in the same foreground
        // session; the worker keeps answering the typed 402.
        harness.retry(.sceneActivated)
        // Short on purpose: this asserts that no second submit arrives.
        #expect(!(await waitUntil(timeout: .milliseconds(500)) { client.analyzeCallCount > 1 }))
        #expect(client.analyzeCallCount == 1)
        #expect(harness.balanceAPI.bootstrapCalls == 1)
    }

    @Test("Every sweep submits the credit deferrals the balance covers and parks the rest")
    func everySweepFiltersCreditDeferralsByHeadroom() async throws {
        for trigger in [TranscriptAnalysisQueue.RetryTrigger.launch, .sceneActivated, .balanceIncreased] {
            let client = ScriptedEpisodeTranscriptAnalysisClient()
            let harness = try await makeDeferredQueueHarness(
                slug: "headroom-\(trigger)",
                episodes: [
                    DeferredEpisodeSpec(kind: .insufficientSeconds),
                    // Ten audio-hours price at 78,500 s, past 14,400 s of headroom.
                    DeferredEpisodeSpec(kind: .insufficientSeconds, audioDuration: 36_000)
                ],
                client: client
            )
            harness.loadAnalysisStore()
            if trigger == .balanceIncreased {
                #expect(await harness.purchases.refreshBalance())
            }
            harness.retry(trigger)

            #expect(await waitUntil {
                harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                    && !harness.transcriptAnalyses.hasActiveJob
            })
            #expect(client.submittedEpisodeIDs == [harness.episodeIDs[0]])
            #expect(harness.transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs == [harness.episodeIDs[1]])
            // Launch and foreground refresh once; a balance increase reads the
            // balance it was handed (the priming refresh above).
            #expect(harness.balanceAPI.bootstrapCalls == 1)
        }
    }

    @Test("A headroom increase that still cannot cover the episode submits nothing; one that covers it does")
    func refreshHeadroomIncreaseWakesOnlyCoveredDeferrals() async throws {
        let client = ScriptedEpisodeTranscriptAnalysisClient()
        let harness = try await makeDeferredQueueHarness(
            slug: "small-topup",
            episodes: [DeferredEpisodeSpec(kind: .insufficientSeconds)],
            client: client,
            balance: Self.exhaustedBalance
        )
        harness.loadAnalysisStore()
        harness.retry(.launch)
        #expect(await waitUntil { harness.balanceAPI.bootstrapCalls == 1 })

        // 20 s of headroom against a 35 s estimate: the refresh fires the
        // balance callback, and its sweep still parks the record.
        harness.balanceAPI.balance = Self.balance(available: 20, debt: 10_800)
        #expect(await harness.purchases.refreshBalance())
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { !client.submittedEpisodeIDs.isEmpty }))

        harness.balanceAPI.balance = Self.coveringBalance
        #expect(await harness.purchases.refreshBalance())
        #expect(await waitUntil {
            harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                && !harness.transcriptAnalyses.hasActiveJob
        })
        #expect(client.submittedEpisodeIDs == harness.episodeIDs)
        // The balance sweeps never refreshed on their own.
        #expect(harness.balanceAPI.bootstrapCalls == 3)
    }

    @Test("A failed refresh parks credit deferrals despite a stale covering balance; cap deferrals still probe")
    func failedRefreshParksCreditDeferralsButCapProbesContinue() async throws {
        let client = ScriptedEpisodeTranscriptAnalysisClient()
        let harness = try await makeDeferredQueueHarness(
            slug: "refresh-fails",
            episodes: [
                DeferredEpisodeSpec(kind: .capExceeded),
                DeferredEpisodeSpec(kind: .insufficientSeconds)
            ],
            client: client
        )
        #expect(await harness.purchases.refreshBalance())
        harness.balanceAPI.bootstrapError = URLError(.notConnectedToInternet)
        harness.loadAnalysisStore()
        harness.retry(.launch)

        #expect(await waitUntil {
            harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                && harness.balanceAPI.bootstrapCalls == 2
                && !harness.transcriptAnalyses.hasActiveJob
        })
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { client.submittedEpisodeIDs.count > 1 }))
        #expect(client.submittedEpisodeIDs == [harness.episodeIDs[0]])
        #expect(harness.transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs == [harness.episodeIDs[1]])

        // The next foreground session's successful refresh recovers it.
        harness.balanceAPI.bootstrapError = nil
        harness.appModel.resetTranscriptAnalysisForegroundProbe()
        harness.retry(.sceneActivated)
        #expect(await waitUntil {
            harness.transcriptAnalyses.record(for: harness.episodeIDs[1])?.state == .completed
                && !harness.transcriptAnalyses.hasActiveJob
        })
        #expect(client.submittedEpisodeIDs == harness.episodeIDs)
    }

    @Test("Overlapping launch, activation and balance callbacks share one refresh and submit each episode once")
    func overlappingSweepsCoalesce() async throws {
        let client = ScriptedEpisodeTranscriptAnalysisClient()
        let harness = try await makeDeferredQueueHarness(
            slug: "overlap",
            episodes: [
                DeferredEpisodeSpec(kind: .insufficientSeconds),
                DeferredEpisodeSpec(kind: .insufficientSeconds)
            ],
            client: client,
            balance: Self.exhaustedBalance
        )
        #expect(await harness.purchases.refreshBalance())
        let gate = SuspensionGate()
        harness.balanceAPI.bootstrapGate = gate
        harness.balanceAPI.balance = Self.coveringBalance
        harness.loadAnalysisStore()

        harness.retry(.launch)
        await gate.waitUntilEntered()
        // Both land while the launch refresh is suspended: a scene
        // activation, and a redeem's headroom callback.
        harness.retry(.sceneActivated)
        harness.purchases.onBalanceIncreased?()
        await gate.open()

        #expect(await waitUntil {
            harness.episodeIDs.allSatisfy {
                harness.transcriptAnalyses.record(for: $0)?.state == .completed
            } && !harness.transcriptAnalyses.hasActiveJob
        })
        harness.retry(.sceneActivated)
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { client.submittedEpisodeIDs.count > 2 }))
        #expect(client.submittedEpisodeIDs == harness.episodeIDs)
        // The priming refresh plus the launch refresh; the applied increase
        // fired the callback without a refresh of its own.
        #expect(harness.balanceAPI.bootstrapCalls == 2)
    }

    @Test("An activation before the store load keeps the launch sweep's turn")
    func activationBeforeLoadKeepsLaunchOpportunity() async throws {
        let client = ScriptedEpisodeTranscriptAnalysisClient()
        let harness = try await makeDeferredQueueHarness(
            slug: "early-activation",
            episodes: [DeferredEpisodeSpec(kind: .insufficientSeconds)],
            client: client
        )
        harness.retry(.sceneActivated)
        #expect(harness.balanceAPI.bootstrapCalls == 0)

        harness.loadAnalysisStore()
        harness.retry(.launch)
        #expect(await waitUntil {
            harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                && !harness.transcriptAnalyses.hasActiveJob
        })
        #expect(client.submittedEpisodeIDs == harness.episodeIDs)
        #expect(harness.balanceAPI.bootstrapCalls == 1)
    }

    @Test("A queued credit retry rechecks headroom before uploading")
    func queuedCreditRetryRechecksHeadroom() async throws {
        let client = ScriptedEpisodeTranscriptAnalysisClient()
        let gate = SuspensionGate()
        client.gate = gate
        let harness = try await makeDeferredQueueHarness(
            slug: "recheck",
            episodes: [
                DeferredEpisodeSpec(kind: nil),
                DeferredEpisodeSpec(kind: .insufficientSeconds)
            ],
            client: client
        )
        let queue = harness.makeStandaloneQueue()
        harness.loadAnalysisStore()
        #expect(await harness.purchases.refreshBalance())

        // A manual run occupies the single-flight store while the balance
        // sweep queues the covered deferral behind it.
        queue.generate(episodeID: harness.episodeIDs[0], modelContext: harness.context)
        await gate.waitUntilEntered()
        queue.retryDeferred(modelContext: harness.context, trigger: .balanceIncreased)
        #expect(await waitUntil { queue.pendingEpisodeIDs == [harness.episodeIDs[1]] })

        // Another device spends the headroom before the retry's turn.
        harness.balanceAPI.balance = Self.exhaustedBalance
        #expect(await harness.purchases.refreshBalance())
        await gate.open()

        #expect(await waitUntil {
            queue.pendingEpisodeIDs.isEmpty && !harness.transcriptAnalyses.hasActiveJob
                && harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
        })
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { client.submittedEpisodeIDs.count > 1 }))
        #expect(client.submittedEpisodeIDs == [harness.episodeIDs[0]])
        #expect(harness.transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs == [harness.episodeIDs[1]])

        // Manual Generate stays unfiltered: the worker decides.
        queue.generate(episodeID: harness.episodeIDs[1], modelContext: harness.context)
        #expect(await waitUntil { client.submittedEpisodeIDs.count == 2 })
    }

    @Test("Cancellation and the data nuke stop a suspended sweep from enqueuing, even when its refresh still answers with more credit")
    func suspendedSweepCannotEnqueueAfterReset() async throws {
        for usesDataNuke in [false, true] {
            let client = ScriptedEpisodeTranscriptAnalysisClient()
            let harness = try await makeDeferredQueueHarness(
                slug: "reset-\(usesDataNuke)",
                episodes: [DeferredEpisodeSpec(kind: .insufficientSeconds)],
                client: client
            )
            let queue = harness.makeStandaloneQueue()
            // A known balance first: the parked refresh then answers with
            // MORE headroom, so a late answer that were applied would also
            // fire the balance-increase callback and start a fresh sweep.
            #expect(await harness.purchases.refreshBalance())
            harness.balanceAPI.balance = Self.balance(available: 10_000, debt: 0)
            let gate = SuspensionGate()
            harness.balanceAPI.bootstrapGate = gate
            harness.loadAnalysisStore()

            queue.retryDeferred(modelContext: harness.context, trigger: .launch)
            await gate.waitUntilEntered()
            if usesDataNuke {
                queue.resetAfterDataNuke()
            } else {
                await queue.cancelPending()
            }
            await gate.open()
            #expect(await waitUntil { harness.balanceAPI.bootstrapCalls == 2 })
            #expect(!(await waitUntil(timeout: .milliseconds(300)) { !client.submittedEpisodeIDs.isEmpty }))
            #expect(queue.pendingEpisodeIDs.isEmpty)
            // The cancelled refresh applied nothing.
            #expect(harness.purchases.balance?.availableSeconds == 3_600)

            // The obsolete pass did not absorb the next sweep.
            queue.retryDeferred(modelContext: harness.context, trigger: .launch)
            #expect(await waitUntil {
                harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                    && !harness.transcriptAnalyses.hasActiveJob
            })
            #expect(client.submittedEpisodeIDs == harness.episodeIDs)
            #expect(harness.balanceAPI.bootstrapCalls == 3)
            #expect(harness.purchases.balance?.availableSeconds == 10_000)
        }
    }

    @Test("Cancellation and the data nuke stop a sweep suspended in a transcript load")
    func sweepSuspendedInTranscriptLoadCannotEnqueueAfterReset() async throws {
        for usesDataNuke in [false, true] {
            let client = ScriptedEpisodeTranscriptAnalysisClient()
            let harness = try await makeDeferredQueueHarness(
                slug: "reset-load-\(usesDataNuke)",
                episodes: [DeferredEpisodeSpec(kind: .insufficientSeconds)],
                client: client
            )
            let queue = harness.makeStandaloneQueue()
            let gate = SuspensionGate()
            let transcriptions = harness.appModel.transcriptions
            queue.loadTranscriptDocument = { episodeID in
                await gate.enter()
                return try await transcriptions.loadDocument(for: episodeID)
            }
            harness.loadAnalysisStore()

            queue.retryDeferred(modelContext: harness.context, trigger: .launch)
            await gate.waitUntilEntered()
            if usesDataNuke {
                queue.resetAfterDataNuke()
            } else {
                await queue.cancelPending()
            }
            await gate.open()
            #expect(!(await waitUntil(timeout: .milliseconds(300)) { !client.submittedEpisodeIDs.isEmpty }))
            #expect(queue.pendingEpisodeIDs.isEmpty)

            queue.retryDeferred(modelContext: harness.context, trigger: .launch)
            #expect(await waitUntil {
                harness.transcriptAnalyses.record(for: harness.episodeIDs[0])?.state == .completed
                    && !harness.transcriptAnalyses.hasActiveJob
            })
            #expect(client.submittedEpisodeIDs == harness.episodeIDs)
        }
    }

    @Test("A fresh denial also stops the sweep that is still loading the next transcript")
    func freshDenialStopsSweepSuspendedInTranscriptLoad() async throws {
        let client = ThrowingEpisodeTranscriptAnalysisClient(error: Self.insufficientSecondsError)
        let harness = try await makeDeferredQueueHarness(
            slug: "halt-during-load",
            episodes: [
                DeferredEpisodeSpec(kind: .insufficientSeconds),
                DeferredEpisodeSpec(kind: .insufficientSeconds)
            ],
            client: client
        )
        let queue = harness.makeStandaloneQueue()
        let gate = SuspensionGate()
        let transcriptions = harness.appModel.transcriptions
        let parkedEpisodeID = harness.episodeIDs[1]
        queue.loadTranscriptDocument = { episodeID in
            if episodeID == parkedEpisodeID {
                await gate.enter()
            }
            return try await transcriptions.loadDocument(for: episodeID)
        }
        harness.loadAnalysisStore()

        // The sweep queues the first episode, then parks on the second's
        // transcript while the first upload is refused with a fresh 402.
        queue.retryDeferred(modelContext: harness.context, trigger: .launch)
        await gate.waitUntilEntered()
        #expect(await waitUntil {
            client.analyzeCallCount == 1
                && !harness.transcriptAnalyses.hasActiveJob
                && queue.pendingEpisodeIDs.isEmpty
        })

        // The balance the sweep relied on has just been contradicted by the
        // worker: resuming must not upload the second episode on it.
        await gate.open()
        #expect(!(await waitUntil(timeout: .milliseconds(500)) { client.analyzeCallCount > 1 }))
        #expect(client.analyzeCallCount == 1)
        #expect(queue.pendingEpisodeIDs.isEmpty)
        #expect(Set(harness.transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs) == Set(harness.episodeIDs))
    }

    // MARK: - Fixtures

    private static var insufficientSecondsError: EpisodeTranscriptAnalysisHTTPError {
        EpisodeTranscriptAnalysisHTTPError(
            statusCode: 402,
            code: "insufficient_transcription_seconds",
            detail: nil
        )
    }

    /// One subscribed show whose episodes carry the given typed deferrals,
    /// stamped oldest-last so the queue drains them in declaration order.
    private func makeDeferredQueueHarness(
        slug: String,
        episodes: [DeferredEpisodeSpec],
        client: any EpisodeTranscriptAnalysisClient,
        balance: OpenCastRemoteTranscriptionBalance? = nil
    ) async throws -> DeferredQueueHarness {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let items = episodes.indices.map { index in
            """
                <item>
                  <title>Episode \(index)</title>
                  <guid>\(slug)-\(index)</guid>
                  <enclosure url="https://example.com/audio/\(slug)-\(index).mp3" type="audio/mpeg" />
                </item>
            """
        }.joined(separator: "\n")
        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>\(slug) Show</title>
                \(items)
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/\(slug).xml")!
        )
        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        let feedURL = snapshot.podcast.id.rawValue
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "\(slug) Show"))
        let base = Date(timeIntervalSince1970: 1_780_500_000)
        let episodeIDs = snapshot.episodes.map(\.id.rawValue)
        for (index, spec) in episodes.enumerated() {
            let episodeID = episodeIDs[index]
            if spec.isTranscribed {
                try seedCompletedTranscript(
                    episodeID: episodeID,
                    podcastID: feedURL,
                    audioDuration: spec.audioDuration,
                    fileStore: transcriptFileStore,
                    context: context
                )
            }
            if let kind = spec.kind {
                insertDeferredRecord(
                    kind: kind,
                    episodeID: episodeID,
                    podcastID: feedURL,
                    updatedAt: base.addingTimeInterval(Double(episodes.count - index) * 10),
                    context: context
                )
            }
        }
        try context.save()

        let (purchases, balanceAPI) = makeBalancePurchaseStore(balance: balance ?? Self.coveringBalance)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            remoteTranscriptionPurchases: purchases,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        // The deferrals model manually started runs, so consent is on file.
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        return DeferredQueueHarness(
            appModel: appModel,
            context: context,
            transcriptAnalyses: transcriptAnalyses,
            purchases: purchases,
            balanceAPI: balanceAPI,
            episodeIDs: episodeIDs
        )
    }

    /// 3,600 s available plus the 10,800 s debt allowance: 14,400 s of
    /// headroom, enough for the 35 s fixture estimate.
    private static let coveringBalance = balance(available: 3_600, debt: 0)
    /// Debt at the cap and nothing available: no headroom at all.
    private static let exhaustedBalance = balance(available: 0, debt: 10_800)

    private static func balance(available: Int64, debt: Int64) -> OpenCastRemoteTranscriptionBalance {
        OpenCastRemoteTranscriptionBalance(
            availableSeconds: available,
            reservedSeconds: 0,
            debtSeconds: debt
        )
    }

    private func makeBalancePurchaseStore(
        balance: OpenCastRemoteTranscriptionBalance = EpisodeTranscriptAnalysisStoreTests.coveringBalance
    ) -> (RemoteTranscriptionPurchaseStore, FakeBalanceAPI) {
        let api = FakeBalanceAPI(balance: balance)
        let store = RemoteTranscriptionPurchaseStore(
            api: api,
            storeKit: LiveRemoteTranscriptionStoreKitClient(),
            configuration: RemoteTranscriptionBackendConfiguration.prodStaging
        )
        return (store, api)
    }

    private func makeTranscriptDocument(
        episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        audioDuration: Double = 16,
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> EpisodeTranscriptDocument {
        let segments = [
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
                text: "This episode is brought to you by Example Sponsor.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]

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
            audioDuration: audioDuration,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    private func seedCompletedTranscript(
        episodeID: String,
        podcastID: String,
        audioDuration: Double = 16,
        fileStore: EpisodeTranscriptFileStore,
        context: ModelContext
    ) throws {
        let document = makeTranscriptDocument(
            episodeID: episodeID,
            podcastID: podcastID,
            audioDuration: audioDuration
        )
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: episodeID,
            podcastID: podcastID,
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
    }

    private func insertCapDeferredRecord(
        episodeID: String,
        podcastID: String,
        updatedAt: Date,
        context: ModelContext
    ) {
        insertDeferredRecord(
            kind: .capExceeded,
            episodeID: episodeID,
            podcastID: podcastID,
            updatedAt: updatedAt,
            context: context
        )
    }

    private func insertDeferredRecord(
        kind: EpisodeAnalysisFailureKind,
        episodeID: String,
        podcastID: String,
        updatedAt: Date,
        context: ModelContext
    ) {
        let record = EpisodeTranscriptAnalysisRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            state: .failed,
            errorMessage: "Deferred by the worker.",
            updatedAt: updatedAt
        )
        record.failureKind = kind
        context.insert(record)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptAnalysisTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct DeferredEpisodeSpec {
    /// Nil seeds a transcribed episode with no analysis record.
    var kind: EpisodeAnalysisFailureKind?
    /// 16 s prices at 35 credit-seconds under the flat analysis rate.
    var audioDuration: Double = 16
    var isTranscribed = true
}

@MainActor
private struct DeferredQueueHarness {
    let appModel: OpenCastAppModel
    let context: ModelContext
    let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    let purchases: RemoteTranscriptionPurchaseStore
    let balanceAPI: FakeBalanceAPI
    let episodeIDs: [String]

    /// A queue over the same stores whose pending list the test can read;
    /// balance increases wake it instead of the app model's own queue.
    func makeStandaloneQueue() -> TranscriptAnalysisQueue {
        let queue = TranscriptAnalysisQueue(
            transcriptAnalyses: appModel.transcriptAnalyses,
            transcriptions: appModel.transcriptions,
            library: appModel.library,
            purchases: purchases
        )
        queue.resolveEpisode = { [appModel] episodeID in
            appModel.episodeSnapshot(for: episodeID)
        }
        purchases.onBalanceIncreased = { [weak queue] in
            queue?.retryDeferredAfterBalanceIncrease()
        }
        return queue
    }

    func loadAnalysisStore() {
        appModel.transcriptAnalyses.load(modelContext: context)
    }

    func retry(_ trigger: TranscriptAnalysisQueue.RetryTrigger) {
        appModel.retryDeferredTranscriptAnalyses(modelContext: context, trigger: trigger)
    }
}

/// One-shot barrier: `enter()` parks callers until `open()`, and
/// `waitUntilEntered()` lets the test resume only once a caller is parked —
/// the deterministic "suspended mid-await" moment.
private actor SuspensionGate {
    private var isOpen = false
    private var hasEntered = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        for waiter in enterWaiters {
            waiter.resume()
        }
        enterWaiters.removeAll()
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !hasEntered else {
            return
        }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters {
            waiter.resume()
        }
        openWaiters.removeAll()
    }
}

private final class GatedEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    private let gate: SuspensionGate

    init(gate: SuspensionGate) {
        self.gate = gate
    }

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        await gate.enter()
        return .completed(EpisodeTranscriptAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeTranscriptAnalysisContract.expectedPolicy,
            chapters: [],
            summary: nil,
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }
}

private final class ThrowingEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    var error: Error?
    private(set) var analyzeCallCount = 0

    init(error: Error?) {
        self.error = error
    }

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        analyzeCallCount += 1
        if let error {
            throw error
        }

        return .completed(EpisodeTranscriptAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeTranscriptAnalysisContract.expectedPolicy,
            chapters: [],
            summary: nil,
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }
}

/// Refuses the first analyze with the typed link-missing 403, then admits
/// everything after a bootstrap: the store's transparent repair path.
private final class BootstrapRepairingEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    private(set) var events: [String] = []

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        events.append("analyze")
        guard events.contains("bootstrap") else {
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: 403,
                code: "bootstrap_required",
                detail: nil
            )
        }
        return .completed(EpisodeTranscriptAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeTranscriptAnalysisContract.expectedPolicy,
            chapters: [
                EpisodeTranscriptAnalysisAPIChapter(
                    title: "Welcome",
                    startSegmentID: 0,
                    endSegmentID: 1,
                    startTime: 0,
                    endTime: 12,
                    confidence: 0.9
                )
            ],
            summary: nil,
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }

    func bootstrapAccount() async throws {
        events.append("bootstrap")
    }
}

private final class FakeEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    private(set) var requests: [EpisodeTranscriptAnalysisAPIRequest] = []
    var policy = EpisodeTranscriptAnalysisContract.expectedPolicy

    var lastRequest: EpisodeTranscriptAnalysisAPIRequest? {
        requests.last
    }

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        requests.append(request)
        return .completed(EpisodeTranscriptAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: policy,
            chapters: [
                EpisodeTranscriptAnalysisAPIChapter(
                    title: "Welcome",
                    startSegmentID: 0,
                    endSegmentID: 0,
                    startTime: 0,
                    endTime: 5,
                    confidence: 0.9
                ),
                EpisodeTranscriptAnalysisAPIChapter(
                    title: "The Sponsor Read",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 5,
                    endTime: 12,
                    confidence: 0.8
                )
            ],
            summary: EpisodeTranscriptAnalysisAPISummary(
                summary: "A warm welcome followed by a sponsor read.",
                oneLineDescription: "A short test episode",
                claims: [
                    EpisodeTranscriptAnalysisAPIClaim(
                        text: "The host welcomes listeners back.",
                        evidenceSegmentID: 0
                    )
                ]
            ),
            warnings: [],
            usage: EpisodeTranscriptAnalysisAPIUsage(
                promptTokenCount: 100,
                candidatesTokenCount: 20,
                thoughtsTokenCount: 30,
                totalTokenCount: 150
            )
        ))
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }
}

/// Records every submit, optionally parks the first one on a gate, and
/// otherwise completes like `FakeEpisodeTranscriptAnalysisClient`.
private final class ScriptedEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    private let lock = NSLock()
    private let completing = FakeEpisodeTranscriptAnalysisClient()
    private var recordedEpisodeIDs: [String] = []
    private var pendingGate: SuspensionGate?

    var gate: SuspensionGate? {
        get { lock.withLock { pendingGate } }
        set { lock.withLock { pendingGate = newValue } }
    }

    var submittedEpisodeIDs: [String] {
        lock.withLock { recordedEpisodeIDs }
    }

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        let gate: SuspensionGate? = lock.withLock {
            recordedEpisodeIDs.append(request.episodeID)
            defer { pendingGate = nil }
            return pendingGate
        }
        await gate?.enter()
        return try await completing.analyze(request)
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }
}

/// Balance-only purchase backend: bootstrap answers with the scripted
/// balance, optionally parked on a gate or failing.
private final class FakeBalanceAPI: RemoteTranscriptionAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var currentBalance: OpenCastRemoteTranscriptionBalance
    private var currentError: Error?
    private var currentGate: SuspensionGate?
    private var recordedBootstrapCalls = 0

    init(balance: OpenCastRemoteTranscriptionBalance) {
        currentBalance = balance
    }

    var balance: OpenCastRemoteTranscriptionBalance {
        get { lock.withLock { currentBalance } }
        set { lock.withLock { currentBalance = newValue } }
    }

    var bootstrapError: Error? {
        get { lock.withLock { currentError } }
        set { lock.withLock { currentError = newValue } }
    }

    var bootstrapGate: SuspensionGate? {
        get { lock.withLock { currentGate } }
        set { lock.withLock { currentGate = newValue } }
    }

    var bootstrapCalls: Int {
        lock.withLock { recordedBootstrapCalls }
    }

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        let gate = lock.withLock {
            recordedBootstrapCalls += 1
            return currentGate
        }
        await gate?.enter()
        if let error = bootstrapError {
            throw error
        }
        return OpenCastRemoteTranscriptionBootstrapResponse(
            schemaVersion: 1,
            accountID: "pacct-fake",
            balance: balance,
            appAccountToken: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            catalog: RemoteTranscriptionEmbeddedCatalog.products,
            catalogSHA256: RemoteTranscriptionEmbeddedCatalog.catalogSHA256,
            purchasesEnabled: true
        )
    }

    func redeem(transactionJWS: String) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        throw Self.unused
    }

    func createJob(_ request: OpenCastRemoteTranscriptionJobCreateRequest) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw Self.unused
    }

    func reportSource(jobID: String, identity: OpenCastRemoteTranscriptionSourceIdentity) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw Self.unused
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        throw Self.unused
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        throw Self.unused
    }

    func ack(jobID: String, normalizedTranscriptSHA256: String?) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw Self.unused
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw Self.unused
    }

    func uploadStart(jobID: String, forBackground: Bool) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        throw Self.unused
    }

    func uploadParts(jobID: String, partNumbers: [Int], forBackground: Bool) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        throw Self.unused
    }

    func uploadComplete(jobID: String, parts: [OpenCastRemoteTranscriptionUploadCompletedPart]) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw Self.unused
    }

    private static var unused: RemoteTranscriptionHTTPError {
        RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }
}
