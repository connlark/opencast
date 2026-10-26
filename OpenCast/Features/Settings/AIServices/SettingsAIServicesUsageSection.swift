import OpenCastAnalysis
import SwiftUI

struct SettingsAIServicesUsageSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Section {
            ForEach(AnalysisProvider.allCases, id: \.self) { provider in
                usageRow(for: provider)
            }
        } header: {
            Text(AIServicesCopy.usageHeader)
        } footer: {
            Text(AIServicesCopy.usageFooter)
        }
    }

    private func usageRow(for provider: AnalysisProvider) -> some View {
        let usage = appModel.analysisUsage.usage(for: provider)

        return VStack(alignment: .leading, spacing: 4) {
            Text(provider.displayName)
            Group {
                if let lastRun = usage.lastRun {
                    Text(
                        AIServicesCopy.usageLastRun(
                            inputTokens: lastRun.inputTokens,
                            outputTokens: lastRun.outputTokens,
                            date: lastRun.at
                        )
                    )
                    Text(
                        AIServicesCopy.usageMonth(
                            inputTokens: usage.monthInputTokens,
                            outputTokens: usage.monthOutputTokens
                        )
                    )
                } else {
                    Text(AIServicesCopy.usageEmpty)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("AI Services Usage \(provider.rawValue)")
    }
}
