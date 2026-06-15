import SwiftUI

struct PlayerUtilityButtonChrome: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .padding(.vertical, verticalPadding)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }

    private var minHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 56 : 78
    }

    private var verticalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 0
    }
}

extension View {
    func playerUtilityButtonChrome() -> some View {
        modifier(PlayerUtilityButtonChrome())
    }
}
