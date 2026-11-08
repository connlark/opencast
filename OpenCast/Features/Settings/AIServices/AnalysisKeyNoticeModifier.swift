import SwiftData
import SwiftUI

/// Presents the one-time key notice for a gate, from the context that owns
/// it (beside that context's ad-detection mode dialog).
struct AnalysisKeyNoticeModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Bindable var gate: AnalysisKeyNoticeGate

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $gate.isNoticePresented, onDismiss: gate.didDismiss) {
                AnalysisKeyNoticeSheet(onOK: ok, onLearnMore: learnMore)
                    .environment(appModel)
                    // Now Playing styles its content; the notice reads as an
                    // ordinary sheet wherever it comes from (the layout sets
                    // its own colors).
                    .font(.body)
            }
            .sheet(item: $gate.helpDestination) { destination in
                SheetDestinationView(destination: destination, onDismiss: dismissHelp)
                    .environment(appModel)
                    .font(.body)
                    .foregroundStyle(Color.primary)
            }
    }

    private func ok() {
        gate.choose(.ok, appModel: appModel, modelContext: modelContext)
    }

    private func learnMore() {
        gate.choose(.learnMore, appModel: appModel, modelContext: modelContext)
    }

    private func dismissHelp() {
        gate.helpDestination = nil
    }
}

extension View {
    func analysisKeyNotice(gate: AnalysisKeyNoticeGate) -> some View {
        modifier(AnalysisKeyNoticeModifier(gate: gate))
    }
}
