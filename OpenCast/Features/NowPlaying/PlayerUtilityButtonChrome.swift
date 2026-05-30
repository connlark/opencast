import SwiftUI

struct PlayerUtilityButtonChrome: ViewModifier {
    private let cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func playerUtilityButtonChrome() -> some View {
        modifier(PlayerUtilityButtonChrome())
    }
}
