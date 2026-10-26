import OpenCastAnalysis
import SwiftData
import SwiftUI

struct SettingsAIServicesProvidersSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            ForEach(AnalysisFeature.allCases, id: \.self) { feature in
                AnalysisProviderPickerRow(title: AIServicesCopy.featureName(feature)) {
                    AnalysisProviderPickerChip(
                        feature: feature,
                        options: options(for: feature),
                        selection: appModel.effectiveAnalysisProvider(for: feature),
                        onSelect: selectProvider(for: feature)
                    )
                }
            }
        } header: {
            Text(AIServicesCopy.providerHeader)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(AIServicesCopy.providersFooter)
                if let message = appModel.analysisProviderSelection.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
        // A menu label in a form row resolves the automatic label style to
        // icon-only, and a chip must read as its model. Set here, never
        // inside the chip's menu label (that placement crashed on iOS 27).
        .labelStyle(.titleAndIcon)
    }

    private func options(for feature: AnalysisFeature) -> [(provider: AnalysisProvider, title: String)] {
        let snapshot = appModel.analysisPolicy.snapshot
        return appModel.analysisProviderSelection
            .eligibleProviders(for: feature, presences: appModel.analysisKeys.presences, snapshot: snapshot)
            .compactMap { provider in
                snapshot.modelEntry(for: feature, provider: provider).map { (provider: provider, title: $0.label) }
            }
    }

    private func selectProvider(for feature: AnalysisFeature) -> (AnalysisProvider) -> Void {
        { provider in
            appModel.analysisProviderSelection.setProvider(provider, for: feature, modelContext: modelContext)
        }
    }
}
