import OpenCastAnalysis
import SwiftUI

/// The one-time notice before the first Detect Ads or Generate tap without a
/// key. Only its two buttons close it; both mark it seen (the presenting gate
/// does that).
struct AnalysisKeyNoticeSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onOK: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        let copy = appModel.analysisKeyNotice.sheetCopy(
            trial: appModel.analysisPolicy.snapshot.bundle.trial,
            now: .now
        )

        AnalysisKeyPromptLayout(
            title: copy.title,
            paragraphs: copy.paragraphs,
            primaryTitle: AIServicesCopy.noticeOK,
            primaryIdentifier: "AI Key Notice OK",
            onPrimary: onOK,
            secondaryTitle: AIServicesCopy.noticeLearnMore,
            secondaryIdentifier: "AI Key Notice Learn More",
            onSecondary: onLearnMore
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
            AnalysisKeyNoticeSheet(onOK: {}, onLearnMore: {})
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    Text("Episode")
        .sheet(isPresented: .constant(true)) {
            AnalysisKeyNoticeSheet(onOK: {}, onLearnMore: {})
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.light)
}
