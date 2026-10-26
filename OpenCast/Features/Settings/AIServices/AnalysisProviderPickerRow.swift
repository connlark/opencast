import SwiftUI

/// One feature's provider row. Every row lays out the same way at a given
/// text size: the chip trails its title (which wraps) at standard sizes and
/// sits under it at accessibility sizes, so the two rows never differ.
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
