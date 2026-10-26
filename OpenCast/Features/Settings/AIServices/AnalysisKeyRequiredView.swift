import OpenCastAnalysis
import SwiftUI

/// Asks for a key when an analysis cannot run on the free analyses, worded by
/// the trial's state, with a route to Settings › AI Services.
struct AnalysisKeyRequiredView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let request: AnalysisKeyRequiredRequest

    var body: some View {
        let trial = appModel.analysisPolicy.snapshot.bundle.trial

        AnalysisKeyPromptLayout(
            title: AIServicesCopy.keyRequiredTitle(request.trialStatus),
            paragraphs: [
                AIServicesCopy.keyRequiredBody(
                    request.trialStatus,
                    trialDate: AIServicesCopy.trialDate(trial.startsAt),
                    lifetimeUnits: trial.lifetimeUnits
                )
            ],
            primaryTitle: AIServicesCopy.keyRequiredOpenSettings,
            primaryIdentifier: "Analysis Key Required Open Settings",
            onPrimary: openSettings,
            secondaryTitle: AIServicesCopy.keyRequiredNotNow,
            secondaryIdentifier: "Analysis Key Required Not Now",
            onSecondary: dismiss.callAsFunction
        )
        // Every way out (either button, a swipe, a replacing sheet) ends
        // this request, and only this one.
        .onDisappear(perform: endRequest)
    }

    private func openSettings() {
        dismiss()
        appModel.requestAIServicesSettingsPresentation()
    }

    private func endRequest() {
        appModel.analysisKeyRequired.dismiss(id: request.id)
    }
}

#Preview("Exhausted") {
    Text("Library")
        .sheet(isPresented: .constant(true)) {
            AnalysisKeyRequiredView(request: AIServicesPreviewSamples.keyRequiredRequest(.exhausted))
                .presentationDetents([.medium, .large])
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.dark)
}

#Preview("Not Started") {
    Text("Library")
        .sheet(isPresented: .constant(true)) {
            AnalysisKeyRequiredView(request: AIServicesPreviewSamples.keyRequiredRequest(.notStarted))
                .presentationDetents([.medium, .large])
        }
        .environment(AIServicesPreviewSamples.appModel())
        .preferredColorScheme(.light)
}
