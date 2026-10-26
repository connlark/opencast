import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// Tokens each provider reported for the analyses run with the listener's
/// key, counted on this device: one device-local record per provider holding
/// the last run and the current UTC month's totals. The analysis runs call
/// `record` once per finished run with the run's totals.
///
/// A month rollover is a read projection against `currentMonth`: the stored
/// bucket is never rewritten on read, and the screen re-renders when
/// `refreshCurrentMonth()` moves `currentMonth` (on appear and foreground).
@Observable
final class AnalysisUsageStore {
    private(set) var currentMonth: String
    private(set) var lastErrorMessage: String?
    private var stored: [AnalysisProvider: AnalysisProviderUsage] = [:]

    @ObservationIgnored private let save: (ModelContext) throws -> Void
    @ObservationIgnored private let now: () -> Date

    /// `save` and `now` are the test seams for preference saves and the clock.
    init(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping () -> Date = { Date.now }
    ) {
        self.save = save
        self.now = now
        currentMonth = Self.month(of: now())
    }

    static func preferenceKey(for provider: AnalysisProvider) -> String {
        "aiServices.usage.\(provider.rawValue)"
    }

    /// The Gregorian year and month of `date` in UTC, as `"yyyy-MM"`, whatever
    /// the device's calendar and time zone.
    nonisolated static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        return "\(year)-\(month < 10 ? "0" : "")\(month)"
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        var loaded: [AnalysisProvider: AnalysisProviderUsage] = [:]
        do {
            for provider in AnalysisProvider.allCases {
                // A record that no longer decodes is dropped; the next run
                // writes a fresh one.
                guard let value = try LocalPreferenceRecord.preference(
                    forKey: Self.preferenceKey(for: provider),
                    modelContext: context
                )?.value,
                    let usage = try? JSONDecoder().decode(AnalysisProviderUsage.self, from: Data(value.utf8))
                else {
                    continue
                }
                loaded[provider] = usage
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to load AI Services usage: \(error.localizedDescription)"
        }
        stored = loaded
        refreshCurrentMonth()
    }

    func refreshCurrentMonth() {
        let month = Self.month(of: now())
        guard month != currentMonth else {
            return
        }
        currentMonth = month
    }

    /// The last run, and this month's totals: zero when the stored bucket is
    /// not `currentMonth`'s.
    func usage(for provider: AnalysisProvider) -> AnalysisProviderUsage {
        guard var usage = stored[provider] else {
            return AnalysisProviderUsage(lastRun: nil, month: currentMonth, monthInputTokens: 0, monthOutputTokens: 0)
        }
        if usage.month != currentMonth {
            usage.month = currentMonth
            usage.monthInputTokens = 0
            usage.monthOutputTokens = 0
        }
        return usage
    }

    /// Adds one finished run. `at` is clamped to now, so a skewed future
    /// stamp never moves the bucket ahead of the clock, and a bucket or last
    /// run already ahead of the clock (recorded while the clock ran fast) is
    /// replaced rather than kept. A run in the stored month adds to its
    /// totals; a later month replaces them with this run's; an earlier month
    /// adds nothing. Negative counts read as zero and sums saturate.
    /// `lastRun` moves only to a later run. With a `runID` the counts are
    /// the run's totals so far: a run already among the newest recorded runs
    /// adds only the part of its totals not counted before (nothing when
    /// they did not grow).
    @discardableResult
    func record(
        provider: AnalysisProvider,
        feature: AnalysisFeature,
        inputTokens: Int,
        outputTokens: Int,
        at: Date,
        runID: String? = nil,
        modelContext: ModelContext
    ) -> Bool {
        let totalInput = max(inputTokens, 0)
        let totalOutput = max(outputTokens, 0)
        let counted = runID.flatMap { runID in stored[provider]?.recentRuns?.first { $0.id == runID } }
        let input = max(totalInput - (counted?.inputTokens ?? 0), 0)
        let output = max(totalOutput - (counted?.outputTokens ?? 0), 0)
        if counted != nil, input == 0, output == 0 {
            return true
        }
        refreshCurrentMonth()
        let stamp = min(at, now())
        let month = Self.month(of: stamp)
        var usage = stored[provider]
            ?? AnalysisProviderUsage(lastRun: nil, month: month, monthInputTokens: 0, monthOutputTokens: 0)
        if usage.month > currentMonth {
            usage.month = month
            usage.monthInputTokens = 0
            usage.monthOutputTokens = 0
        }
        if let lastRun = usage.lastRun, lastRun.at > now() {
            usage.lastRun = nil
        }
        if month == usage.month {
            usage.monthInputTokens = Self.saturatingSum(usage.monthInputTokens, input)
            usage.monthOutputTokens = Self.saturatingSum(usage.monthOutputTokens, output)
        } else if month > usage.month {
            usage.month = month
            usage.monthInputTokens = input
            usage.monthOutputTokens = output
        }
        // A run recorded again under its id may restate its own totals at
        // the same instant.
        if usage.lastRun.map({ stamp > $0.at || (counted != nil && stamp >= $0.at) }) ?? true {
            usage.lastRun = AnalysisProviderUsage.Run(
                feature: feature.rawValue,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                at: stamp
            )
        }
        if let runID {
            var recent = (usage.recentRuns ?? []).filter { $0.id != runID }
            recent.append(AnalysisProviderUsage.CountedRun(
                id: runID,
                inputTokens: max(totalInput, counted?.inputTokens ?? 0),
                outputTokens: max(totalOutput, counted?.outputTokens ?? 0)
            ))
            usage.recentRuns = Array(recent.suffix(AnalysisProviderUsage.recentRunLimit))
        }
        guard persist(usage, for: provider, modelContext: modelContext) else {
            return false
        }
        stored[provider] = usage
        return true
    }

    private func persist(_ usage: AnalysisProviderUsage, for provider: AnalysisProvider, modelContext: ModelContext) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(usage)
            try LocalPreferenceRecord.upsert(
                key: Self.preferenceKey(for: provider),
                value: String(decoding: data, as: UTF8.self),
                modelContext: context
            )
            try save(context)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to update AI Services usage: \(error.localizedDescription)"
            return false
        }
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
