import OpenCastAnalysis
import SwiftUI

struct SettingsAIServicesModelsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        let cards = AnalysisModelCardContent.cards(in: appModel.analysisPolicy.snapshot)
        if !cards.isEmpty {
            Section {
                ForEach(cards) { card in
                    AnalysisModelCardRow(card: card)
                }
            } header: {
                Text(AIServicesCopy.modelsHeader)
            } footer: {
                Text(AIServicesCopy.modelsFooter)
            }
        }
    }
}
