import SwiftUI

struct PlayerUtilityCircleChrome: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = 52.0

    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(.title3)
            .foregroundStyle(
                isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
            )
            .frame(width: max(44, scaledDiameter), height: max(44, scaledDiameter))
            .contentShape(.circle)
            .overlay {
                Circle()
                    .strokeBorder(
                        isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        lineWidth: isActive ? 2 : 0
                    )
                    .padding(3)
            }
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

extension View {
    func playerUtilityCircleChrome(isActive: Bool = false) -> some View {
        modifier(PlayerUtilityCircleChrome(isActive: isActive))
    }
}
