import SwiftUI

/// One row of the Shows picker: a 40-point leading image, the title, and a
/// checkmark while the row is included. The whole row is one button, and
/// its accessibility label is the title alone.
struct PlaylistShowsPickerRow<Leading: View>: View {
    let title: String
    let isSelected: Bool
    /// The row's identifier suffix: a feed URL, or "all".
    let identifier: String
    let action: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("shows-picker-row-\(identifier)")
    }
}
