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
            .sheet(isPresented: $gate.isNoticePresented, onDismiss: didDismiss) {
                AnalysisKeyNoticeSheet(onAddKey: addKey, onLater: later)
                    .environment(appModel)
                    // Now Playing styles its content; the notice reads as an
                    // ordinary sheet wherever it comes from (the layout sets
                    // its own colors).
                    .font(.body)
            }
    }

    private func addKey() {
        gate.choose(.addKey, appModel: appModel, modelContext: modelContext)
    }

    private func later() {
        gate.choose(.later, appModel: appModel, modelContext: modelContext)
    }

    private func didDismiss() {
        gate.didDismiss(appModel: appModel)
    }
}

extension View {
    func analysisKeyNotice(gate: AnalysisKeyNoticeGate) -> some View {
        modifier(AnalysisKeyNoticeModifier(gate: gate))
    }
}
