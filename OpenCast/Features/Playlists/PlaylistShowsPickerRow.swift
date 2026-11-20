import SwiftUI

struct PlaylistShowsPickerRow<Leading: View>: View {
    let title: String
    let accessory: PlaylistShowsPickerRowAccessory
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

                trailingImage
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(accessory == .checkmark(isSelected: true) ? .isSelected : [])
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var trailingImage: some View {
        switch accessory {
        case .checkmark(let isSelected):
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(isSelected ? 1 : 0)
        case .add:
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
        case .remove:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityHint: String {
        switch accessory {
        case .checkmark:
            ""
        case .add:
            "Adds to First"
        case .remove:
            "Removes from First"
        }
    }
}
