import OpenCastAnalysis
import SwiftUI

struct SettingsAIServicesNoticeSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        if let freeTierDay {
            Section {
                Label(markText(day: freeTierDay), systemImage: "info.circle")
                    .accessibilityIdentifier("AI Services Free Tier Mark")
            }
        } else if appModel.analysisKeyNotice.showsSettingsNoticeRow(
            hasSavedKey: appModel.analysisKeys.hasSavedKey,
            reachability: appModel.analysisTrialReachability.state
        ) {
            Section {
                Label(
                    appModel.analysisKeyNotice.settingsRowText(trial: trial, now: .now),
                    systemImage: "info.circle"
                )
                .accessibilityIdentifier("AI Services Notice Row")
            }
        }
    }

    private var trial: AnalysisTrialPolicy {
        appModel.analysisPolicy.snapshot.bundle.trial
    }

    private var freeTierDay: Date? {
        guard case .freeTier(let day) = appModel.analysisKeyTier.state,
              appModel.analysisKeys.presence(for: .google).isSaved
        else {
            return nil
        }
        return day
    }

    private func markText(day: Date) -> String {
        let answerDay = AIServicesCopy.answerDay(day)
        return appModel.analysisTrialReachability.isHandoverWindowOpen(trialStartsAt: trial.startsAt, now: .now)
            ? AIServicesCopy.freeTierMarkInHandoverWindow(day: answerDay, date: AIServicesCopy.trialDate(trial.startsAt))
            : AIServicesCopy.freeTierMark(day: answerDay)
    }
}
