import SwiftData
import SwiftUI

struct AnalysisKeyNoticeModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Bindable var gate: AnalysisKeyNoticeGate

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $gate.isNoticePresented, onDismiss: gate.didDismiss) {
                AnalysisKeyNoticeSheet(onOK: ok, onLearnMore: learnMore)
                    .environment(appModel)
                    // Now Playing styles its content; this keeps the notice an ordinary sheet.
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
