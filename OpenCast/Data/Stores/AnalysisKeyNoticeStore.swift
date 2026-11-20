import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// The seen flag lives in `LocalPreferenceRecord`, so a data nuke shows the notice again.
@Observable
final class AnalysisKeyNoticeStore {
    static let seenPreferenceKey = "aiServices.keyNoticeSeen"
    /// Not `true`: an earlier build stored `true`, and that value must read as unseen.
    static let seenPreferenceValue = "2"

    private(set) var hasSeenAIKeyNotice = false
    var trialStatus: AnalysisTrialStatus?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

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
            // A failed persist only shows the notice again on a later launch.
        }
    }

    func isNoticeDue(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSeenAIKeyNotice && showsSettingsNoticeRow(hasSavedKey: hasSavedKey, reachability: reachability)
    }

    func isAwaitingReachability(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSeenAIKeyNotice && !hasSavedKey && reachability == .unknown
    }

    func showsSettingsNoticeRow(hasSavedKey: Bool, reachability: AnalysisTrialReachability.State) -> Bool {
        !hasSavedKey && reachability == .available
    }

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
