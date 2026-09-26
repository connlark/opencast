import SwiftUI

struct PlayerUtilityCircleChrome: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = 52.0

    let isActive: Bool
    let progress: Double?

    func body(content: Content) -> some View {
        content
            .font(.title3)
            .foregroundStyle(
                isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
            )
            .frame(width: max(44, scaledDiameter), height: max(44, scaledDiameter))
            .contentShape(.circle)
            .overlay {
                if let progress {
                    Circle()
                        .strokeBorder(.tint.opacity(0.2), lineWidth: 2)
                        .padding(3)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            .tint,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                } else {
                    Circle()
                        .strokeBorder(
                            isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                            lineWidth: isActive ? 2 : 0
                        )
                        .padding(3)
                }
            }
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

extension View {
    func playerUtilityCircleChrome(
        isActive: Bool = false,
        progress: Double? = nil
    ) -> some View {
        modifier(PlayerUtilityCircleChrome(isActive: isActive, progress: progress))
    }
}
