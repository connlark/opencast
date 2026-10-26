import OpenCastAnalysis
import SwiftUI

/// One provider's key status; a tap opens that provider's key sheet. The row
/// owns its sheet, so the sheet is keyed by the provider it was opened for.
struct SettingsAIServicesProviderRow: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let provider: AnalysisProvider

    @State private var isEditingKey = false

    var body: some View {
        let presence = appModel.analysisKeys.presence(for: provider)
        let isUnread = appModel.analysisKeys.lastReadFailed(provider)

        Button(action: editKey) {
            LabeledContent {
                Text(isUnread ? AIServicesCopy.statusUnavailable : AIServicesCopy.status(presence))
                    .foregroundStyle(.secondary)
            } label: {
                Text(provider.displayName)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isUnread ? AIServicesCopy.statusUnavailable : AIServicesCopy.statusAccessibilityValue(presence))
        .accessibilityHint(AIServicesCopy.providerRowHint(provider))
        .accessibilityIdentifier("AI Services Provider \(provider.rawValue)")
        .sheet(isPresented: $isEditingKey) {
            AnalysisProviderKeySheet(provider: provider)
                .environment(appModel)
        }
    }

    private func editKey() {
        isEditingKey = true
    }
}
