import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// The one-time notice that ad detection and Chapters & Summary move to the
/// listener's own key, and the trial facts the AI Services screens show.
/// The seen flag lives in `LocalPreferenceRecord` with the rest of the
/// wipeable local state: a data nuke deletes it and the notice shows again.
@Observable
final class AnalysisKeyNoticeStore {
    static let seenPreferenceKey = "aiServices.keyNoticeSeen"
    static let seenPreferenceValue = "true"

    private(set) var hasSeenAIKeyNotice = false
    /// A display fact: the trial status cache sets it; UI tests seed it.
    var trialStatus: AnalysisTrialStatus?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// `save` is the test seam for the seen flag's save.
    init(
        trialStatus: AnalysisTrialStatus? = nil,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.trialStatus = trialStatus
        self.save = save
    }

    func load(modelContext: ModelContext) {
        // A failed read only means the notice can show again.
        let record = try? LocalPreferenceRecord.preference(
            forKey: Self.seenPreferenceKey,
            modelContext: ModelContext(modelContext.container)
        )
        hasSeenAIKeyNotice = record?.value == Self.seenPreferenceValue
    }

    func markSeen(modelContext: ModelContext) {
        hasSeenAIKeyNotice = true
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.seenPreferenceKey,
                value: Self.seenPreferenceValue,
                modelContext: context
            )
            try save(context)
        } catch {
            // The listener's answer stands for this session; a failed
            // persist only shows the notice again on a later launch.
        }
    }

    /// Before the first analysis that would use a key: unseen, no key saved,
    /// and the bundle's notice has started. A bundle without a notice never
    /// shows one.
    func isNoticeDue(notice: AnalysisNoticePolicy?, hasSavedKey: Bool, now: Date) -> Bool {
        !hasSeenAIKeyNotice && showsSettingsNoticeRow(notice: notice, hasSavedKey: hasSavedKey, now: now)
    }

    /// The AI Services row stays after the notice was seen, until a key is
    /// saved.
    func showsSettingsNoticeRow(notice: AnalysisNoticePolicy?, hasSavedKey: Bool, now: Date) -> Bool {
        !hasSavedKey && (notice?.startsAt ?? .distantFuture) <= now
    }

    func remainingUnits(trial: AnalysisTrialPolicy) -> Int {
        switch trialStatus {
        case .unitsLeft(let units): max(units, 0)
        case .exhausted: 0
        case .notStarted, nil: trial.lifetimeUnits
        }
    }
}
