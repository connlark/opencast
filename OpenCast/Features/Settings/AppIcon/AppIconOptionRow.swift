import SwiftUI

struct AppIconOptionRow: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let option: AppIconOption

    private var isSelected: Bool {
        appModel.appIcon.selection == option
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 16) {
                // ictool renders carry the squircle mask with transparent corners.
                Image(option.previewImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .foregroundStyle(Color.primary)
                    Text(option.caption)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(appModel.appIcon.isApplying)
        .accessibilityIdentifier("App Icon Option \(option.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select() {
        Task { await appModel.appIcon.select(option) }
    }
}
