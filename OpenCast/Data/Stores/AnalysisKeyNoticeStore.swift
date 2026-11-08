import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// The one-time notice that ad detection and Chapters & Summary are included
/// until the trial date, and the trial facts the AI Services screens show.
/// The seen flag lives in `LocalPreferenceRecord` with the rest of the
/// wipeable local state: a data nuke deletes it and the notice shows again.
@Observable
final class AnalysisKeyNoticeStore {
    static let seenPreferenceKey = "aiServices.keyNoticeSeen"
    /// 2026.11.1 stored `true` for a sheet that pushed a key early; the calm
    /// sheet corrects it, so that value reads as unseen.
    static let seenPreferenceValue = "2"

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

    /// Before the first analysis without a key: unseen, no key saved, and the
    /// trial service reachable, so "included until the date" is true here.
    func isNoticeDue(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSeenAIKeyNotice && showsSettingsNoticeRow(hasSavedKey: hasSavedKey, reachability: reachability)
    }

    /// A tap that must wait for reachability before the gate can answer.
    func isAwaitingReachability(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSeenAIKeyNotice && !hasSavedKey && reachability == .unknown
    }

    /// The AI Services row stays after the notice was seen, until a key is
    /// saved.
    func showsSettingsNoticeRow(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSavedKey && reachability == .available
    }

    /// The count the service reported for this install; `nil` when it has
    /// reported none, which does not justify "this install has N left".
    var knownRemainingUnits: Int? {
        switch trialStatus {
        case .unitsLeft(let units): max(units, 0)
        case .exhausted: 0
        case .notStarted, nil: nil
        }
    }

    func sheetCopy(trial: AnalysisTrialPolicy, now: Date) -> (title: String, paragraphs: [String]) {
        if now < trial.startsAt {
            let date = AIServicesCopy.trialDate(trial.startsAt)
            return (
                AIServicesCopy.noticeTitle(date: date),
                [
                    AIServicesCopy.noticeFirstParagraph(date: date),
                    AIServicesCopy.noticeSecondParagraph(units: trial.lifetimeUnits)
                ]
            )
        }
        let body = knownRemainingUnits.map(AIServicesCopy.noticeBodyCountKnown)
            ?? AIServicesCopy.noticeBodyCountUnknown(units: trial.lifetimeUnits)
        return (AIServicesCopy.noticeTitleFromTrialDate, [body])
    }

    func settingsRowText(trial: AnalysisTrialPolicy, now: Date) -> String {
        if now < trial.startsAt {
            return AIServicesCopy.noticeRowBeforeTrial(
                date: AIServicesCopy.trialDate(trial.startsAt),
                units: trial.lifetimeUnits
            )
        }
        switch knownRemainingUnits {
        case nil: return AIServicesCopy.noticeRowCountUnknown(units: trial.lifetimeUnits)
        case 0: return AIServicesCopy.noticeRowExhausted
        case let units?: return AIServicesCopy.noticeRowUnitsLeft(units)
        }
    }
}
