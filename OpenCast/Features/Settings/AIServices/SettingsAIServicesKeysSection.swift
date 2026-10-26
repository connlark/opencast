import OpenCastAnalysis
import SwiftUI

struct SettingsAIServicesKeysSection: View {
    var body: some View {
        Section {
            ForEach(AnalysisProvider.allCases, id: \.self) { provider in
                SettingsAIServicesProviderRow(provider: provider)
            }
        } header: {
            Text(AIServicesCopy.keysHeader)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(AIServicesCopy.geminiPrivacyFootnote)
                HelpFooterLink(title: "How your own key works", topicID: HelpTopicID.aiKeys)
            }
        }
    }
}
