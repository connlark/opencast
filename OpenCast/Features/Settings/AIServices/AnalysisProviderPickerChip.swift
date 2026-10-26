import OpenCastAnalysis
import SwiftUI

/// Which provider one analysis runs on: a glass chip showing the effective
/// provider's model label, opening a menu of the providers with a saved key
/// and a qualified model. With none, a still chip reads "No key".
struct AnalysisProviderPickerChip: View {
    let feature: AnalysisFeature
    /// Eligible providers in display order, each with its model label.
    let options: [(provider: AnalysisProvider, title: String)]
    let selection: AnalysisProvider?
    let onSelect: (AnalysisProvider) -> Void

    var body: some View {
        if let selection, let selectedTitle = title(for: selection) {
            Menu {
                Picker(AIServicesCopy.pickerLabel(feature), selection: binding(selected: selection)) {
                    ForEach(options, id: \.provider) { option in
                        Text(option.title)
                            .tag(option.provider)
                    }
                }
            } label: {
                AnalysisProviderChipLabel(title: selectedTitle, isInteractive: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(AIServicesCopy.pickerLabel(feature))
            .accessibilityValue(selectedTitle)
            .accessibilityInputLabels([AIServicesCopy.pickerLabel(feature), selectedTitle])
            .accessibilityIdentifier("AI Services Picker \(feature.rawValue)")
        } else {
            AnalysisProviderChipLabel(title: AIServicesCopy.noKey, isInteractive: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AIServicesCopy.pickerLabel(feature))
                .accessibilityValue(AIServicesCopy.noKey)
                .accessibilityIdentifier("AI Services Picker \(feature.rawValue)")
        }
    }

    private func title(for provider: AnalysisProvider) -> String? {
        options.first { $0.provider == provider }?.title
    }

    /// Re-picking the checked provider calls `onSelect` too, which makes the
    /// effective provider the stored choice.
    private func binding(selected: AnalysisProvider) -> Binding<AnalysisProvider> {
        Binding {
            selected
        } set: { provider in
            onSelect(provider)
        }
    }
}
