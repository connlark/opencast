import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// Callable from any isolation: every read and write runs under one lock, and the files are small.
nonisolated final class AnalysisRunRecordStore: Sendable {
    static let maximumRecords = 200
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    let directory: URL
    private let now: @Sendable () -> Date
    private let state = Mutex<[String: AnalysisRunRecord]?>(nil)

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "AnalysisRuns", directoryHint: .isDirectory),
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.directory = directory
        self.now = now
    }

    // MARK: Records

    func begin(_ record: AnalysisRunRecord) throws {
        try state.withLock { cache in
            var records = loaded(&cache)
            records[record.id] = record
            try write(record)
            cache = records
        }
    }

    func observer(runID: String) -> any AnalysisProviderSendObserver {
        AnalysisRunRecordSendObserver(store: self, runID: runID)
    }

    func finish(
        runID: String,
        outcome: AnalysisOutcome,
        listenerFailure: AnalysisProviderFailure?,
        background: Bool?
    ) {
        update(runID: runID) { record in
            record.background = background
            record.listenerFailure = listenerFailure?.rawValue
            record.finishedAt = now()
            switch outcome {
            case .adDetection, .chaptersSummary:
                record.state = .finished
                record.outcomeCode = "completed"
                for key in record.windows.keys { record.windows[key]?.verdict = .accepted }
            case .failed(let failure):
                record.state = failure.code == .cancelled ? .cancelled : .failed
                record.outcomeCode = failure.code.rawValue
                for (key, window) in record.windows where window.verdict == .dispatched || window.verdict == .repairing {
                    record.windows[key]?.verdict = .cancelled
                }
                if let index = failure.windowIndex {
                    record.windows[String(index), default: .init(verdict: .failed, sends: 0)].verdict = .failed
                }
            }
        }
        deleteReplies(runID: runID)
    }

    func markCancelled(runID: String) {
        update(runID: runID) { record in
            record.state = .cancelled
            record.outcomeCode = AnalysisFailureCode.cancelled.rawValue
            record.finishedAt = now()
        }
        deleteReplies(runID: runID)
    }

    func markExpired(runID: String) {
        update(runID: runID) { record in
            record.state = .expired
        }
    }

    func markUsageRecorded(runID: String) {
        update(runID: runID) { record in
            record.usageRecorded = true
        }
    }

    func unaccountedDirectRuns(feature: AnalysisFeature) -> [AnalysisRunRecord] {
        state.withLock { cache in
            loaded(&cache).values
                .filter { record in
                    record.feature == feature && record.route == .direct && record.usageRecorded != true
                        && record.state != .dispatched && record.state != .expired
                        && (record.inputTokens > 0 || record.outputTokens > 0)
                }
                .sorted { $0.startedAt < $1.startedAt }
        }
    }

    func record(id: String) -> AnalysisRunRecord? {
        state.withLock { cache in loaded(&cache)[id] }
    }

    /// Includes `expired` runs: both states may resume.
    func latestDispatched(feature: AnalysisFeature, episodeID: String) -> AnalysisRunRecord? {
        state.withLock { cache in
            loaded(&cache).values
                .filter { $0.feature == feature && $0.episodeID == episodeID && ($0.state == .dispatched || $0.state == .expired) }
                .max { $0.startedAt < $1.startedAt }
        }
    }

    /// A kill after the handover record was written can leave both open. Never pick between them by
    /// time: `startedAt` persists at ISO 8601 precision and a clock change can reorder them.
    func runsTakenOverByOpenHandovers(feature: AnalysisFeature) -> [String] {
        state.withLock { cache in
            let records = loaded(&cache)
            return records.values
                .filter { $0.feature == feature && Self.isOpen($0) }
                .compactMap(\.handoverOf)
                .filter { id in records[id].map(Self.isOpen) ?? false }
        }
    }

    func finishTakenOver(runID: String) {
        update(runID: runID) { record in
            record.state = .failed
            record.finishedAt = now()
            for (key, window) in record.windows where window.verdict == .dispatched || window.verdict == .repairing {
                record.windows[key]?.verdict = .cancelled
            }
        }
        deleteReplies(runID: runID)
    }

    private static func isOpen(_ record: AnalysisRunRecord) -> Bool {
        record.state == .dispatched || record.state == .expired
    }

    func records(limit: Int) -> [AnalysisRunRecord] {
        state.withLock { cache in
            Array(loaded(&cache).values.sorted { $0.startedAt > $1.startedAt }.prefix(max(limit, 0)))
        }
    }

    func prune() {
        state.withLock { cache in
            cache = pruned(loaded(&cache))
        }
    }

    /// Call under the lock; removes the dropped records' files and sidecars.
    private func pruned(_ records: [String: AnalysisRunRecord]) -> [String: AnalysisRunRecord] {
        var kept = records
        let cutoff = now().addingTimeInterval(-Self.retention)
        let ordered = records.values.sorted { $0.startedAt > $1.startedAt }
        for (index, record) in ordered.enumerated() where index >= Self.maximumRecords || record.startedAt < cutoff {
            kept[record.id] = nil
            try? FileManager.default.removeItem(at: recordURL(record.id))
            try? FileManager.default.removeItem(at: repliesURL(record.id))
        }
        return kept
    }

    /// For a run whose document was installed before the process stopped short of `finish`.
    func finishInstalled(runID: String) {
        update(runID: runID) { record in
            guard record.state == .dispatched || record.state == .expired else { return }
            record.state = .finished
            record.outcomeCode = "completed"
            record.finishedAt = now()
            for key in record.windows.keys { record.windows[key]?.verdict = .accepted }
        }
        deleteReplies(runID: runID)
    }

    func deleteAll() {
        state.withLock { cache in
            try? FileManager.default.removeItem(at: directory)
            cache = [:]
        }
    }

    func update(runID: String, _ change: (inout AnalysisRunRecord) -> Void) {
        state.withLock { cache in
            var records = loaded(&cache)
            guard var record = records[runID] else { return }
            change(&record)
            records[runID] = record
            try? write(record)
            cache = records
        }
    }

    // MARK: Replies

    func replies(runID: String) -> [AnalysisRunReplyKey: AnalysisRunStoredReply] {
        state.withLock { _ in readReplies(runID) ?? [:] }
    }

    func saveReply(_ reply: AnalysisRunStoredReply, for key: AnalysisRunReplyKey, runID: String) {
        state.withLock { _ in
            // An unreadable sidecar is left as it is, never replaced by this one reply.
            guard var replies = readReplies(runID) else { return }
            replies[key] = reply
            let entries = replies.map { AnalysisRunReplyEntry(key: $0.key, reply: $0.value) }
                .sorted { $0.key.purpose < $1.key.purpose }
            guard let data = try? Self.encoder.encode(entries) else { return }
            try? ensureDirectory()
            try? data.write(to: repliesURL(runID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func deleteReplies(runID: String) {
        state.withLock { _ in
            try? FileManager.default.removeItem(at: repliesURL(runID))
        }
    }

    // MARK: Files

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func recordURL(_ id: String) -> URL {
        directory.appending(path: "\(id).json", directoryHint: .notDirectory)
    }

    private func repliesURL(_ id: String) -> URL {
        directory.appending(path: "\(id).replies.json", directoryHint: .notDirectory)
    }

    private func loaded(_ cache: inout [String: AnalysisRunRecord]?) -> [String: AnalysisRunRecord] {
        if let cache { return cache }
        var records: [String: AnalysisRunRecord] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".replies.json") {
            guard let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(AnalysisRunRecord.self, from: data)
            else {
                continue
            }
            records[record.id] = record
        }
        let kept = pruned(records)
        cache = kept
        return kept
    }

    private func write(_ record: AnalysisRunRecord) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(record)
        try data.write(to: recordURL(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Empty when there is no sidecar; `nil` when one exists but cannot be read.
    private func readReplies(_ runID: String) -> [AnalysisRunReplyKey: AnalysisRunStoredReply]? {
        let url = repliesURL(runID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let entries = try? Self.decoder.decode([AnalysisRunReplyEntry].self, from: data)
        else {
            return nil
        }
        return Dictionary(entries.map { ($0.key, $0.reply) }, uniquingKeysWith: { _, last in last })
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try excluded.setResourceValues(values)
    }
}

nonisolated struct AnalysisRunRecordSendObserver: AnalysisProviderSendObserver {
    let store: AnalysisRunRecordStore
    let runID: String

    func record(_ send: AnalysisProviderSendRecord) {
        store.update(runID: runID) { record in
            let key = String(send.purpose.windowIndex ?? 0)
            var window = record.windows[key] ?? .init(verdict: .dispatched, sends: 0)
            window.sends += 1
            let isRepair = if case .adRepair = send.purpose { true } else { false }
            if send.cancelled {
                window.verdict = .cancelled
            } else if send.failure == nil {
                window.verdict = .answered
            } else {
                window.verdict = isRepair ? .repairing : .dispatched
            }
            record.windows[key] = window
            if let usage = send.usage {
                record.inputTokens = record.inputTokens.addingReportingOverflow(usage.input).overflow
                    ? .max : record.inputTokens + usage.input
                record.outputTokens = record.outputTokens.addingReportingOverflow(usage.output).overflow
                    ? .max : record.outputTokens + usage.output
            }
            if send.pacedSeconds.isFinite { record.pacedSeconds += max(send.pacedSeconds, 0) }
            if send.exchangeSeconds.isFinite { record.exchangeSeconds += max(send.exchangeSeconds, 0) }
        }
    }
}
