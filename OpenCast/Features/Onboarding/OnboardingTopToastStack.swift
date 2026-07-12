import SwiftUI

struct OnboardingTopToastStack: View {
    let isWhisperModelInstallToastPresented: Bool
    let importedSubscriptionsNotification: ImportedSubscriptionsNotification?

    var body: some View {
        VStack(spacing: stackSpacing) {
            if isWhisperModelInstallToastPresented {
                WhisperModelInstallToast()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

            if let importedSubscriptionsNotification {
                ImportedSubscriptionsNotificationBanner(notification: importedSubscriptionsNotification)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var stackSpacing: CGFloat {
        isWhisperModelInstallToastPresented && importedSubscriptionsNotification != nil ? -6 : 0
    }
}
