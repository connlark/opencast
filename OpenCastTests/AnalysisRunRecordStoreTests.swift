import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

@Suite("Analysis run records")
struct AnalysisRunRecordStoreTests {
    static let start = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25T12:00:00Z

    /// A run directory of its own, removed at the end of the test.
    final class Directory: Sendable {
        let url = AnalysisRunTestFixtures.temporaryDirectory()

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func store(now: @escaping @Sendable () -> Date = { AnalysisRunRecordStoreTests.start }) -> AnalysisRunRecordStore {
            AnalysisRunRecordStore(directory: url, now: now)
        }

        func fileExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: url.appending(path: name).path(percentEncoded: false))
        }

        func text(_ name: String) throws -> String {
            try String(contentsOf: url.appending(path: name), encoding: .utf8)
        }
    }

    static var trialPolicy: AnalysisRoutePolicy {
        AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: AnalysisRunTestFixtures.snapshot)!
    }

    static func record(
        id: String = UUID().uuidString,
        feature: AnalysisFeature = .adDetection,
        episodeID: String = "episode-1",
        startedAt: Date = start,
        route: AnalysisRoute = .trial
    ) -> AnalysisRunRecord {
        let policy: AnalysisRoutePolicy = switch feature {
        case .adDetection: trialPolicy
        case .chaptersSummary: .chaptersSummary(AnalysisPolicySnapshot.baked.chaptersSummary(provider: .google)!)
        }
        return AnalysisRunRecord(
            id: id,
            feature: feature,
            episodeID: episodeID,
            podcastID: "podcast-1",
            transcriptFingerprint: "fixture-fingerprint",
            resolution: AnalysisRouteResolution(feature: feature, route: route, policy: policy, key: nil, resumingRunID: nil, trialExchange: nil),
            policy: policy,
            startedAt: startedAt
        )
    }

    static func send(
        _ purpose: AnalysisProviderRequest.Purpose,
        failure: AnalysisProviderFailure? = nil,
        cancelled: Bool = false,
        usage: AnalysisBilledUsage? = nil,
        paced: Double = 0,
        exchange: Double = 0
    ) -> AnalysisProviderSendRecord {
        AnalysisProviderSendRecord(
            provider: .google,
            modelID: "gemini-3.8-flash",
            feature: .adDetection,
            purpose: purpose,
            sendIndex: 0,
            status: failure == nil && !cancelled ? 200 : nil,
            finishReason: nil,
            failure: failure,
            cancelled: cancelled,
            usage: usage,
            pacedSeconds: paced,
            exchangeSeconds: exchange
        )
    }

    @Test("begin writes the record before anything is sent, and a new launch reads it")
    func beginWritesFirst() throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()

        try store.begin(record)

        #expect(directory.fileExists("\(record.id).json"))
        #expect(!directory.fileExists("\(record.id).replies.json"))
        let relaunched = directory.store()
        let read = try #require(relaunched.record(id: record.id))
        #expect(read == record)
        #expect(read.state == .dispatched)
        #expect(read.route == .trial)
        #expect(read.provider == .google)
        #expect(read.modelID == Self.trialPolicy.model.modelID)
        #expect(read.policyRevision == Self.trialPolicy.revision)
        #expect(read.bundleVersion == Self.trialPolicy.bundleVersion)
        #expect(read.windows.isEmpty)
    }

    @Test("Sends set window verdicts and add tokens and seconds, across executions of the same id")
    func observerAccumulates() throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()
        try store.begin(record)
        let observer = store.observer(runID: record.id)
        let usage = AnalysisBilledUsage(input: 1_000, cached: 0, write: 0, output: 200, reasoning: 50)

        observer.record(Self.send(.adWindow(index: 0), usage: usage, paced: 1.5, exchange: 4))
        observer.record(Self.send(.adWindow(index: 1), failure: .timeout, exchange: 2))
        observer.record(Self.send(.adWindow(index: 2), failure: .malformedAnswer, usage: usage, exchange: 3))
        observer.record(Self.send(.adRepair(index: 2), failure: .timeout))
        observer.record(Self.send(.adWindow(index: 3), cancelled: true))
        observer.record(Self.send(.adWindow(index: 4), paced: .nan, exchange: -3))

        var read = try #require(store.record(id: record.id))
        #expect(read.windows["0"] == .init(verdict: .answered, sends: 1))
        #expect(read.windows["1"] == .init(verdict: .dispatched, sends: 1))
        #expect(read.windows["2"] == .init(verdict: .repairing, sends: 2))
        #expect(read.windows["3"] == .init(verdict: .cancelled, sends: 1))
        #expect(read.windows["4"] == .init(verdict: .answered, sends: 1))
        #expect(read.inputTokens == 2_000)
        #expect(read.outputTokens == 400)
        #expect(read.pacedSeconds == 1.5)
        #expect(read.exchangeSeconds == 9)

        // A later launch resumes the run: its sends add to the same totals.
        let relaunched = directory.store()
        relaunched.observer(runID: record.id).record(Self.send(.adWindow(index: 1), usage: usage, exchange: 1))
        read = try #require(directory.store().record(id: record.id))
        #expect(read.windows["1"] == .init(verdict: .answered, sends: 2))
        #expect(read.inputTokens == 3_000)
        #expect(read.outputTokens == 600)
        #expect(read.exchangeSeconds == 10)

        // A send for a run with no record changes nothing.
        relaunched.observer(runID: "missing-run").record(Self.send(.adWindow(index: 0), usage: usage))
        #expect(relaunched.record(id: "missing-run") == nil)
    }

    @Test("A finished run marks every window accepted and drops its replies")
    func finishSuccess() async throws {
        let directory = Directory()
        let store = directory.store(now: { AnalysisRunRecordStoreTests.start.addingTimeInterval(90) })
        let record = Self.record()
        try store.begin(record)
        let observer = store.observer(runID: record.id)
        observer.record(Self.send(.adWindow(index: 0)))
        observer.record(Self.send(.adWindow(index: 1), failure: .timeout))
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: record.id)
        #expect(directory.fileExists("\(record.id).replies.json"))

        store.finish(runID: record.id, outcome: await AnalysisRunTestFixtures.successfulOutcome(), listenerFailure: nil, background: true)

        let read = try #require(directory.store().record(id: record.id))
        #expect(read.state == .finished)
        #expect(read.outcomeCode == "completed")
        #expect(read.listenerFailure == nil)
        #expect(read.background == true)
        #expect(read.finishedAt == Self.start.addingTimeInterval(90))
        #expect(read.windows.values.allSatisfy { $0.verdict == .accepted })
        #expect(!directory.fileExists("\(record.id).replies.json"))
        #expect(store.replies(runID: record.id).isEmpty)
    }

    @Test("A failed run marks its failing window failed and its unfinished windows cancelled")
    func finishFailure() throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()
        try store.begin(record)
        let observer = store.observer(runID: record.id)
        observer.record(Self.send(.adWindow(index: 0)))
        observer.record(Self.send(.adWindow(index: 1), failure: .timeout))
        observer.record(Self.send(.adWindow(index: 2), failure: .malformedAnswer))
        observer.record(Self.send(.adRepair(index: 2), failure: .malformedAnswer))
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: record.id)

        let failure = AnalysisFailure(feature: .adDetection, code: .adAnalysisIncomplete, status: 422, windowIndex: 2)
        store.finish(runID: record.id, outcome: .failed(failure), listenerFailure: .malformedAnswer, background: false)

        let read = try #require(store.record(id: record.id))
        #expect(read.state == .failed)
        #expect(read.outcomeCode == "ad_analysis_incomplete")
        #expect(read.listenerFailure == "malformed_answer")
        #expect(read.windows["0"]?.verdict == .answered)
        #expect(read.windows["1"]?.verdict == .cancelled)
        #expect(read.windows["2"]?.verdict == .failed)
        #expect(store.replies(runID: record.id).isEmpty)

        // The runner's cancellation ends the run as cancelled.
        let cancelled = Self.record()
        try store.begin(cancelled)
        store.finish(runID: cancelled.id, outcome: .failed(AnalysisFailure(feature: .adDetection, code: .cancelled, status: 503)), listenerFailure: nil, background: nil)
        #expect(store.record(id: cancelled.id)?.state == .cancelled)
        #expect(store.record(id: cancelled.id)?.outcomeCode == "cancelled")
    }

    @Test("markCancelled ends the run and drops its replies; markExpired keeps both resumable")
    func cancelAndExpire() throws {
        let directory = Directory()
        let store = directory.store()
        let key = AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "ab")
        let cancelled = Self.record()
        let expired = Self.record()
        try store.begin(cancelled)
        try store.begin(expired)
        store.saveReply(.geminiBody("{}"), for: key, runID: cancelled.id)
        store.saveReply(.geminiBody("{\"kept\":true}"), for: key, runID: expired.id)

        store.markCancelled(runID: cancelled.id)
        store.markExpired(runID: expired.id)

        let relaunched = directory.store()
        #expect(relaunched.record(id: cancelled.id)?.state == .cancelled)
        #expect(relaunched.record(id: cancelled.id)?.outcomeCode == "cancelled")
        #expect(relaunched.record(id: cancelled.id)?.finishedAt == Self.start)
        #expect(relaunched.replies(runID: cancelled.id).isEmpty)
        #expect(relaunched.record(id: expired.id)?.state == .expired)
        #expect(relaunched.record(id: expired.id)?.finishedAt == nil)
        #expect(relaunched.replies(runID: expired.id) == [key: .geminiBody("{\"kept\":true}")])
        #expect(relaunched.latestDispatched(feature: .adDetection, episodeID: "episode-1")?.id == expired.id)
    }

    @Test("latestDispatched is the newest open run of that feature on that episode")
    func latestDispatched() throws {
        let directory = Directory()
        let store = directory.store()
        let older = Self.record(startedAt: Self.start)
        let newer = Self.record(startedAt: Self.start.addingTimeInterval(60))
        let newestFinished = Self.record(startedAt: Self.start.addingTimeInterval(120))
        let otherEpisode = Self.record(episodeID: "episode-2", startedAt: Self.start.addingTimeInterval(180))
        let otherFeature = Self.record(feature: .chaptersSummary, startedAt: Self.start.addingTimeInterval(240))
        for record in [older, newer, newestFinished, otherEpisode, otherFeature] {
            try store.begin(record)
        }
        store.markCancelled(runID: newestFinished.id)

        #expect(store.latestDispatched(feature: .adDetection, episodeID: "episode-1")?.id == newer.id)
        store.markExpired(runID: newer.id)
        #expect(store.latestDispatched(feature: .adDetection, episodeID: "episode-1")?.id == newer.id)
        store.markCancelled(runID: newer.id)
        #expect(store.latestDispatched(feature: .adDetection, episodeID: "episode-1")?.id == older.id)
        #expect(store.latestDispatched(feature: .chaptersSummary, episodeID: "episode-1")?.id == otherFeature.id)
        #expect(store.latestDispatched(feature: .adDetection, episodeID: "episode-3") == nil)
    }

    @Test("records(limit:) lists the newest first")
    func recordsNewestFirst() throws {
        let directory = Directory()
        let store = directory.store()
        let records = (0..<5).map { Self.record(startedAt: Self.start.addingTimeInterval(Double($0) * 60)) }
        for record in records.shuffled() {
            try store.begin(record)
        }

        #expect(store.records(limit: 3).map(\.id) == records.reversed().prefix(3).map(\.id))
        #expect(store.records(limit: 10).count == 5)
        #expect(store.records(limit: 0).isEmpty)
        #expect(store.records(limit: -1).isEmpty)
        #expect(directory.store().records(limit: 5).map(\.id) == records.reversed().map(\.id))
    }

    @Test("prune keeps the newest 200 records younger than 90 days, with their files")
    func prune() throws {
        let directory = Directory()
        let now = Self.start
        let store = directory.store(now: { now })
        let tooOld = Self.record(startedAt: now.addingTimeInterval(-AnalysisRunRecordStore.retention - 1))
        let edge = Self.record(startedAt: now.addingTimeInterval(-AnalysisRunRecordStore.retention + 60))
        try store.begin(tooOld)
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: tooOld.id)
        try store.begin(edge)
        let recent = (0..<AnalysisRunRecordStore.maximumRecords).map { Self.record(startedAt: now.addingTimeInterval(-Double($0))) }
        for record in recent {
            try store.begin(record)
        }

        store.prune()

        let kept = Set(directory.store().records(limit: 1_000).map(\.id))
        #expect(kept == Set(recent.map(\.id)))
        #expect(!directory.fileExists("\(tooOld.id).json"))
        #expect(!directory.fileExists("\(tooOld.id).replies.json"))
        #expect(!directory.fileExists("\(edge.id).json"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(files.count == AnalysisRunRecordStore.maximumRecords)

        // Under the cap, only age prunes.
        let small = Directory()
        let smallStore = small.store(now: { now })
        try smallStore.begin(tooOld)
        try smallStore.begin(edge)
        smallStore.prune()
        #expect(smallStore.records(limit: 10).map(\.id) == [edge.id])
    }

    @Test("deleteAll removes every record and reply")
    func deleteAll() throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()
        try store.begin(record)
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: record.id)

        store.deleteAll()

        #expect(store.records(limit: 10).isEmpty)
        #expect(store.record(id: record.id) == nil)
        #expect(store.replies(runID: record.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path(percentEncoded: false)))
        #expect(directory.store().records(limit: 10).isEmpty)

        // The store keeps working after Delete Data.
        try store.begin(Self.record())
        #expect(store.records(limit: 10).count == 1)
    }

    @Test("The record file has sorted keys, ISO 8601 dates and no key, text or URL")
    func fileShape() async throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()
        try store.begin(record)
        store.observer(runID: record.id).record(Self.send(.adWindow(index: 0), usage: .init(input: 10, cached: 0, write: 0, output: 2, reasoning: 0)))
        store.finish(runID: record.id, outcome: await AnalysisRunTestFixtures.successfulOutcome(), listenerFailure: nil, background: false)

        let text = try directory.text("\(record.id).json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "feature", "episode_id", "podcast_digest", "transcript_fingerprint", "route", "provider", "model_id",
            "model_label", "bundle_version", "policy_source", "policy_revision", "started_at", "state", "windows",
            "input_tokens", "output_tokens", "paced_seconds", "exchange_seconds", "outcome_code", "background",
            "finished_at",
        ])
        #expect(object["started_at"] as? String == "2026-10-25T12:00:00Z")
        #expect(object["finished_at"] as? String == "2026-10-25T12:00:00Z")
        #expect(object["route"] as? String == "trial")
        #expect(object["policy_source"] as? String == "baked")
        #expect(object["feature"] as? String == "ad_detection")

        // Keys appear in sorted order, at every level.
        let topLevelOrder = Self.keyOrder(in: text)
        #expect(topLevelOrder == topLevelOrder.sorted())
        #expect(text.contains(#""windows":{"0":{"sends":1,"verdict":"accepted"}}"#))

        for forbidden in ["http", "segments", "text", "key\"", "AIza", "sk-", AnalysisRunTestFixtures.segmentText(0)] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }

    @Test("The podcast id is kept only as its digest")
    func podcastDigest() throws {
        let record = Self.record()
        #expect(record.podcastDigest == AnalysisRunRecord.digest("podcast-1"))
        #expect(record.podcastDigest.count == 64)
        #expect(record.podcastDigest != "podcast-1")
    }

    @Test("finishInstalled ends an open run as finished and drops its replies; an ended run is left alone")
    func finishInstalledEndsOpenRuns() async throws {
        let directory = Directory()
        let store = directory.store()
        let open = Self.record()
        try store.begin(open)
        store.observer(runID: open.id).record(Self.send(.adWindow(index: 0), usage: .init(input: 10, cached: 0, write: 0, output: 2, reasoning: 0)))
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: open.id)
        store.finishInstalled(runID: open.id)
        #expect(store.record(id: open.id)?.state == .finished)
        #expect(store.record(id: open.id)?.windows["0"]?.verdict == .accepted)
        #expect(!directory.fileExists("\(open.id).replies.json"))

        let cancelled = Self.record()
        try store.begin(cancelled)
        store.markCancelled(runID: cancelled.id)
        store.finishInstalled(runID: cancelled.id)
        #expect(store.record(id: cancelled.id)?.state == .cancelled)
    }

    @Test("A new launch prunes past retention when it first reads the records")
    func firstLoadPrunes() throws {
        let directory = Directory()
        let writer = directory.store()
        let old = Self.record(startedAt: Self.start.addingTimeInterval(-AnalysisRunRecordStore.retention - 60))
        let fresh = Self.record()
        try writer.begin(old)
        try writer.begin(fresh)

        let reader = directory.store()
        #expect(reader.record(id: old.id) == nil)
        #expect(reader.record(id: fresh.id) != nil)
        #expect(!directory.fileExists("\(old.id).json"))
    }

    @Test("A sidecar that cannot be read is neither reused nor replaced")
    func unreadableSidecarKept() throws {
        let directory = Directory()
        let store = directory.store()
        let record = Self.record()
        try store.begin(record)
        try Data("not json".utf8).write(to: directory.url.appending(path: "\(record.id).replies.json"))

        #expect(store.replies(runID: record.id).isEmpty)
        store.saveReply(.geminiBody("{}"), for: AnalysisRunReplyKey(purpose: "ad_window_0", payloadSHA256: "00"), runID: record.id)
        #expect(try directory.text("\(record.id).replies.json") == "not json")
    }

    @Test("The run directory is excluded from backup")
    func excludedFromBackup() throws {
        let directory = Directory()
        try directory.store().begin(Self.record())

        let values = try directory.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("The default directory is Application Support/AnalysisRuns")
    func defaultDirectory() {
        #expect(AnalysisRunRecordStore().directory == URL.applicationSupportDirectory.appending(path: "AnalysisRuns", directoryHint: .isDirectory))
    }

    /// The record's top-level keys in file order.
    static func keyOrder(in text: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
            } else if character == "\"" {
                let close = text[text.index(after: index)...].firstIndex(of: "\"")!
                let token = String(text[text.index(after: index)..<close])
                let next = text.index(after: close)
                if depth == 1, next < text.endIndex, text[next] == ":" { keys.append(token) }
                index = next
                continue
            }
            index = text.index(after: index)
        }
        return keys
    }
}
