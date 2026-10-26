import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// The run records, one JSON file per run under
/// `Application Support/AnalysisRuns/<id>.json` (atomic replace, excluded
/// from backup, sorted keys, ISO 8601 dates), plus each unfinished run's
/// sidecar of provider replies (`<id>.replies.json`) that a resume answers
/// windows from. Callable from any isolation: every read and write runs
/// under one lock, and the files are small.
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

    /// Writes a new run's record before its first dispatch.
    func begin(_ record: AnalysisRunRecord) throws {
        try state.withLock { cache in
            var records = loaded(&cache)
            records[record.id] = record
            try write(record)
            cache = records
        }
    }

    /// The observer a run's transport reports its sends to; each send
    /// updates the record's windows, tokens and seconds.
    func observer(runID: String) -> any AnalysisProviderSendObserver {
        AnalysisRunRecordSendObserver(store: self, runID: runID)
    }

    /// Ends a run with its outcome.
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

    /// Ends a run the listener or the app stopped.
    func markCancelled(runID: String) {
        update(runID: runID) { record in
            record.state = .cancelled
            record.outcomeCode = AnalysisFailureCode.cancelled.rawValue
            record.finishedAt = now()
        }
        deleteReplies(runID: runID)
    }

    /// Marks a run whose card expired; it stays resumable with its replies.
    func markExpired(runID: String) {
        update(runID: runID) { record in
            record.state = .expired
        }
    }

    /// Notes that the run's totals so far are saved in the listener's usage.
    func markUsageRecorded(runID: String) {
        update(runID: runID) { record in
            record.usageRecorded = true
        }
    }

    /// Direct runs of `feature` that ended with tokens their usage never
    /// saved (the save failed, or the process stopped first), oldest first.
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

    /// The newest run of `feature` on `episodeID` that may resume
    /// (`dispatched` or `expired`).
    func latestDispatched(feature: AnalysisFeature, episodeID: String) -> AnalysisRunRecord? {
        state.withLock { cache in
            loaded(&cache).values
                .filter { $0.feature == feature && $0.episodeID == episodeID && ($0.state == .dispatched || $0.state == .expired) }
                .max { $0.startedAt < $1.startedAt }
        }
    }

    /// The newest records first.
    func records(limit: Int) -> [AnalysisRunRecord] {
        state.withLock { cache in
            Array(loaded(&cache).values.sorted { $0.startedAt > $1.startedAt }.prefix(max(limit, 0)))
        }
    }

    /// Keeps the newest ``maximumRecords`` records younger than
    /// ``retention``; called at load.
    func prune() {
        state.withLock { cache in
            cache = pruned(loaded(&cache))
        }
    }

    /// `records` without those past retention, whose files (and sidecars)
    /// are removed. Runs under the lock.
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

    /// Ends a run whose document was installed before the process stopped
    /// short of `finish`: the run counts as finished and its sidecar goes.
    /// Does nothing to a run already ended.
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

    /// Removes every record and sidecar (Delete Data).
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

    /// The replies an unfinished run kept, keyed by request.
    func replies(runID: String) -> [AnalysisRunReplyKey: AnalysisRunStoredReply] {
        state.withLock { _ in readReplies(runID) ?? [:] }
    }

    /// Keeps one accepted reply for a resume of the same run.
    func saveReply(_ reply: AnalysisRunStoredReply, for key: AnalysisRunReplyKey, runID: String) {
        state.withLock { _ in
            // A sidecar that exists but cannot be read is left as it is,
            // never replaced by this one reply.
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

    /// The kept replies; empty when there is no sidecar, `nil` when one
    /// exists but could not be read.
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

/// Feeds a run's sends into its record.
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
