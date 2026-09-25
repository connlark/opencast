import SwiftUI

/// A device-local settings store's last error, pinned under the navigation
/// bar (`safeAreaInset(edge: .top)`) of the screen those settings shape.
struct SettingsErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }
}
