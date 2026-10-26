import OpenCastAnalysis
import SwiftUI

/// The one-time notice before the first Detect Ads or Generate tap once the
/// bundle's notice has started. Only its two buttons close it; both mark it
/// seen (the presenting gate does that).
struct AnalysisKeyNoticeSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onAddKey: () -> Void
    let onLater: () -> Void

    var body: some View {
        let trial = appModel.analysisPolicy.snapshot.bundle.trial
        let date = AIServicesCopy.trialDate(trial.startsAt)

        AnalysisKeyPromptLayout(
            title: AIServicesCopy.noticeTitle,
            paragraphs: [
                AIServicesCopy.noticeFirstParagraph(date: date),
                AIServicesCopy.noticeSecondParagraph(date: date, units: trial.lifetimeUnits)
            ],
            primaryTitle: AIServicesCopy.noticeAddKey,
            primaryIdentifier: "AI Key Notice Add Key",
            onPrimary: onAddKey,
            secondaryTitle: AIServicesCopy.noticeLater,
            secondaryIdentifier: "AI Key Notice Later",
            onSecondary: onLater
        )
        .interactiveDismissDisabled()
        // The notice's two paragraphs do not fit a medium sheet at the
        // default text size.
        .presentationDetents([.large])
    }
}

#Preview("Dark") {
    Text("Episode")
        .sheet(isPresented: .constant(true)) {
            AnalysisKeyNoticeSheet(onAddKey: {}, onLater: {})
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    Text("Episode")
        .sheet(isPresented: .constant(true)) {
            AnalysisKeyNoticeSheet(onAddKey: {}, onLater: {})
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.light)
}
