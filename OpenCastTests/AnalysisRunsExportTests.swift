import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

@Suite("Analysis runs export")
struct AnalysisRunsExportTests {
    static let startedAt = Date(timeIntervalSince1970: 1_793_000_000)

    @Test("The export is a versioned envelope of closed fields, nulls included")
    func envelopeShape() throws {
        let finished = Self.record(id: "6F1C2A3B-0000-4000-8000-000000000001", feature: .chaptersSummary, route: .direct) { record in
            record.state = .finished
            record.outcomeCode = "completed"
            record.background = true
            record.windows = ["0": .init(verdict: .accepted, sends: 1)]
            record.inputTokens = 8_430
            record.outputTokens = 912
            record.exchangeSeconds = 14.2
            record.finishedAt = Self.startedAt.addingTimeInterval(15)
        }
        let dispatched = Self.record(id: "6F1C2A3B-0000-4000-8000-000000000002", feature: .adDetection, route: .trial) { _ in }
        let data = try AnalysisRunsExport.data(
            entries: [finished, dispatched].map(AnalysisRunsExportEntry.init),
            generatedAt: Self.startedAt.addingTimeInterval(60)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["format_version", "generated_at", "analysis_runs"])
        #expect(json["format_version"] as? Int == 1)
        #expect(json["generated_at"] as? String == "2026-10-26T07:34:20Z")
        let runs = try #require(json["analysis_runs"] as? [[String: Any]])
        #expect(runs.count == 2)
        #expect(Set(runs[0].keys) == [
            "run_id", "feature", "route", "provider", "model_id", "bundle_version", "policy_source",
            "policy_revision", "state", "background", "outcome_code", "listener_failure", "windows", "sends",
            "input_tokens", "output_tokens", "paced_seconds", "exchange_seconds", "started_at", "finished_at",
        ])
        #expect(Set(runs[1].keys) == Set(runs[0].keys))
        #expect(runs[0]["run_id"] as? String == "6F1C2A3B-0000-4000-8000-000000000001")
        #expect(runs[0]["feature"] as? String == "chapters_summary")
        #expect(runs[0]["route"] as? String == "direct")
        #expect(runs[0]["provider"] as? String == "google")
        #expect(runs[0]["model_id"] as? String == "gemini-3.8-flash")
        #expect(runs[0]["policy_revision"] as? String == "transcript_analysis_v2")
        #expect(runs[0]["state"] as? String == "finished")
        #expect(runs[0]["outcome_code"] as? String == "completed")
        #expect(runs[0]["background"] as? Bool == true)
        #expect(runs[0]["input_tokens"] as? Int == 8_430)
        #expect((runs[0]["windows"] as? [String: Int]) == ["total": 1, "accepted": 1, "failed": 0])
        #expect(runs[0]["sends"] as? Int == 1)
        #expect(runs[1]["route"] as? String == "trial")
        #expect(runs[1]["state"] as? String == "dispatched")
        #expect(runs[1]["outcome_code"] is NSNull)
        #expect(runs[1]["finished_at"] is NSNull)
        #expect(runs[1]["background"] is NSNull)
    }

    @Test("Free-form fields that fail their grammar export as invalid; ids, titles and addresses never export")
    func grammarsFailClosed() throws {
        let record = Self.record(
            id: "not-a-uuid",
            feature: .chaptersSummary,
            route: .direct,
            modelID: "gemini 3.8 flash https://example.com",
            revision: "see https://example.com/policy for details"
        ) { record in
            record.state = .failed
            record.outcomeCode = "Provider said: overloaded"
            record.listenerFailure = "the key AIza… was refused"
        }
        let entry = AnalysisRunsExportEntry(record)
        #expect(entry.runID == "invalid")
        #expect(entry.modelID == "invalid")
        #expect(entry.policyRevision == "invalid")
        #expect(entry.outcomeCode == "invalid")
        #expect(entry.listenerFailure == "invalid")

        let text = String(decoding: try AnalysisRunsExport.data(entries: [entry], generatedAt: Self.startedAt), as: UTF8.self)
        for absent in ["export-episode", "https://example.com/export-feed.xml", "export-fingerprint", "Export Model Label", "https://"] {
            #expect(!text.contains(absent), "\(absent) reached the export")
        }
    }

    @Test("Known outcome codes and listener failures pass through")
    func knownValuesPassThrough() {
        let record = Self.record(id: UUID().uuidString, feature: .chaptersSummary, route: .trial) { record in
            record.state = .failed
            record.outcomeCode = AnalysisFailureCode.providerRejected.rawValue
            record.listenerFailure = AnalysisProviderFailure.trialExhausted.rawValue
            record.windows = ["0": .init(verdict: .failed, sends: 2)]
        }
        let entry = AnalysisRunsExportEntry(record)
        #expect(entry.outcomeCode == "gemini_http_error")
        #expect(entry.listenerFailure == "trial_exhausted")
        #expect(entry.windows == .init(total: 1, accepted: 0, failed: 1))
        #expect(entry.sends == 2)
    }

    @Test("An empty history is an error, and the export keeps at most the newest 200 runs")
    func emptyAndCapped() throws {
        let destination = URL.temporaryDirectory.appending(path: "analysis-runs-export-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(throws: AnalysisRunsExportError.empty) {
            _ = try AnalysisRunsExport.write(entries: [], generatedAt: .now, to: destination)
        }

        let entries = (0..<205).map { index in
            AnalysisRunsExportEntry(Self.record(id: UUID().uuidString, feature: .adDetection, route: .direct) { record in
                record.inputTokens = UInt64(index)
            })
        }
        let url = try AnalysisRunsExport.write(entries: entries, generatedAt: .now, to: destination)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let runs = try #require(json["analysis_runs"] as? [[String: Any]])
        #expect(runs.count == 200)
        #expect(runs.first?["input_tokens"] as? Int == 0)
    }

    @Test("The episode block shows the latest run of each feature with the export's fields")
    func episodeBlock() throws {
        let older = Self.record(id: UUID().uuidString, feature: .chaptersSummary, route: .direct, startedAt: Self.startedAt) { record in
            record.state = .failed
            record.listenerFailure = "invalid_key"
        }
        let newer = Self.record(id: UUID().uuidString, feature: .chaptersSummary, route: .trial, startedAt: Self.startedAt.addingTimeInterval(60)) { record in
            record.state = .finished
            record.outcomeCode = "completed"
            record.background = true
        }
        let ads = Self.record(id: UUID().uuidString, feature: .adDetection, route: .direct) { _ in }
        let elsewhere = Self.record(id: UUID().uuidString, feature: .adDetection, route: .direct, episodeID: "another-episode") { _ in }

        let section = EpisodeDiagnosticsModel.analysisRunsSection(
            records: [older, newer, ads, elsewhere],
            episodeID: "export-episode"
        )
        let rows = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.label, $0.value) })
        #expect(rows["Chapters & Summary · Route"] == "trial")
        #expect(rows["Chapters & Summary · Run ID"] == newer.id)
        #expect(rows["Chapters & Summary · Background"] == EpisodeDiagnosticsFormatting.bool(true))
        #expect(rows["Ad Detection · Run ID"] == ads.id)
        #expect(!section.rows.contains { $0.value == elsewhere.id })
        #expect(section.footnote != nil)

        let empty = EpisodeDiagnosticsModel.analysisRunsSection(records: [elsewhere], episodeID: "export-episode")
        #expect(empty.rows.map(\.value) == ["No analysis runs for this episode."])
    }

    static func record(
        id: String,
        feature: AnalysisFeature,
        route: AnalysisRunRecord.Route,
        episodeID: String = "export-episode",
        modelID: String = "gemini-3.8-flash",
        revision: String? = nil,
        startedAt: Date = startedAt,
        _ change: (inout AnalysisRunRecord) -> Void
    ) -> AnalysisRunRecord {
        let snapshot = AnalysisPolicySnapshot.baked
        let policy: AnalysisRoutePolicy = switch feature {
        case .adDetection:
            .adDetection(Self.relabeled(snapshot.adDetection(provider: .google)!, modelID: modelID, revision: revision))
        case .chaptersSummary:
            .chaptersSummary(Self.relabeled(snapshot.chaptersSummary(provider: .google)!, modelID: modelID, revision: revision))
        }
        var record = AnalysisRunRecord(
            id: id,
            feature: feature,
            episodeID: episodeID,
            podcastID: "https://example.com/export-feed.xml",
            transcriptFingerprint: "export-fingerprint",
            resolution: AnalysisRouteResolution(
                feature: feature,
                route: route == .direct ? .direct(provider: .google) : .trial,
                policy: policy,
                key: nil,
                resumingRunID: nil,
                trialExchange: nil
            ),
            policy: policy,
            startedAt: startedAt
        )
        change(&record)
        return record
    }

    private static func relabeled(_ policy: AdDetectionAnalysisPolicy, modelID: String, revision: String?) -> AdDetectionAnalysisPolicy {
        var settings = policy.settings
        if let revision { settings.revision = revision }
        var model = policy.model
        model.modelID = modelID
        model.label = "Export Model Label"
        return AnalysisPolicy(bundleVersion: policy.bundleVersion, source: policy.source, settings: settings, model: model)
    }

    private static func relabeled(_ policy: ChaptersSummaryAnalysisPolicy, modelID: String, revision: String?) -> ChaptersSummaryAnalysisPolicy {
        var settings = policy.settings
        if let revision { settings.revision = revision }
        var model = policy.model
        model.modelID = modelID
        model.label = "Export Model Label"
        return AnalysisPolicy(bundleVersion: policy.bundleVersion, source: policy.source, settings: settings, model: model)
    }
}
