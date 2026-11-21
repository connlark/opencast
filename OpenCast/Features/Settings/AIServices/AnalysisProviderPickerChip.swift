import OpenCastAnalysis
import SwiftUI

struct AnalysisProviderPickerChip: View {
    let feature: AnalysisFeature
    /// The entries of providers with a saved key, in display order.
    let options: [AnalysisModelEntry]
    let selection: AnalysisModelEntry?
    let onSelect: (AnalysisModelIdentity) -> Void

    var body: some View {
        if let selection {
            Menu {
                Picker(AIServicesCopy.pickerLabel(feature), selection: binding(selected: selection.identity)) {
                    ForEach(options, id: \.identity) { option in
                        Text(option.label)
                            .tag(option.identity)
                    }
                }
            } label: {
                AnalysisProviderChipLabel(title: selection.label, isInteractive: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(AIServicesCopy.pickerLabel(feature))
            .accessibilityValue(selection.label)
            .accessibilityInputLabels([AIServicesCopy.pickerLabel(feature), selection.label])
            .accessibilityIdentifier("AI Services Picker \(feature.rawValue)")
        } else {
            AnalysisProviderChipLabel(title: AIServicesCopy.noKey, isInteractive: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AIServicesCopy.pickerLabel(feature))
                .accessibilityValue(AIServicesCopy.noKey)
                .accessibilityIdentifier("AI Services Picker \(feature.rawValue)")
        }
    }

    /// Re-picking the checked model calls `onSelect` too, which makes the
    /// effective model the stored choice.
    private func binding(selected: AnalysisModelIdentity) -> Binding<AnalysisModelIdentity> {
        Binding {
            selected
        } set: { model in
            onSelect(model)
        }
    }
}
