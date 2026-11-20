import SwiftUI

/// The layout follows the text size, not the fit, so the two rows never differ.
struct AnalysisProviderPickerRow<Chip: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    @ViewBuilder let chip: Chip

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                titleText
                chip
            }
        } else {
            HStack(spacing: 12) {
                titleText
                    .frame(maxWidth: .infinity, alignment: .leading)
                chip
                    .fixedSize()
            }
        }
    }

    /// The chip's own label names the feature, so VoiceOver reads it once.
    private var titleText: some View {
        Text(title)
            .accessibilityHidden(true)
    }
}
