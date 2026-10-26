import OpenCastAnalysis
import SwiftUI

/// The standing reminder that ad detection and Chapters & Summary move to the
/// listener's own key, shown until a key is saved (seeing the one-time
/// notice does not hide it).
struct SettingsAIServicesNoticeSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        let bundle = appModel.analysisPolicy.snapshot.bundle
        let now = Date.now

        if appModel.analysisKeyNotice.showsSettingsNoticeRow(
            notice: bundle.notice,
            hasSavedKey: appModel.analysisKeys.hasSavedKey,
            now: now
        ) {
            Section {
                Label(rowText(trial: bundle.trial, now: now), systemImage: "info.circle")
                    .accessibilityIdentifier("AI Services Notice Row")
            }
        }
    }

    private func rowText(trial: AnalysisTrialPolicy, now: Date) -> String {
        let remainingUnits = appModel.analysisKeyNotice.remainingUnits(trial: trial)
        if trial.startsAt > now {
            return AIServicesCopy.noticeRowBeforeTrial(
                date: AIServicesCopy.trialDate(trial.startsAt),
                units: remainingUnits
            )
        }
        return remainingUnits > 0
            ? AIServicesCopy.noticeRowUnitsLeft(remainingUnits)
            : AIServicesCopy.noticeRowExhausted
    }
}
