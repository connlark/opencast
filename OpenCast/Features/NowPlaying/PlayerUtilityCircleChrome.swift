import SwiftUI

struct PlayerUtilityCircleChrome: ViewModifier {
    nonisolated static let defaultDiameter = 52.0
    nonisolated static let minimumDiameter = 44.0

    @Environment(\.playerUtilityCircleCeiling) private var ceiling
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = Self.defaultDiameter

    let isActive: Bool
    let progress: Double?
    /// The speed button's label is text, fitted like the symbols' glyphs.
    let labelIsText: Bool

    func body(content: Content) -> some View {
        let size = PlayerUtilityCircleSize(scaledDiameter: scaledDiameter, playButtonDiameter: ceiling)
        content
            .font(labelIsText ? size.speedTextFont : size.glyphFont)
            .foregroundStyle(
                isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
            )
            .frame(width: size.diameter, height: size.diameter)
            .contentShape(.circle)
            .overlay {
                if let progress {
                    Circle()
                        .strokeBorder(.tint.opacity(0.2), lineWidth: 2)
                        .padding(3)

                    Circle()
                        .inset(by: 1)
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

    /// The circle never outgrows the play button resolved at the same Dynamic
    /// Type size (`NowPlayingTransportControls.resolvedPlayButtonDiameter`).
    nonisolated static func diameter(scaled: Double, playButtonDiameter: Double) -> Double {
        max(minimumDiameter, min(scaled, playButtonDiameter))
    }
}

extension EnvironmentValues {
    /// The resolved play-button diameter `NowPlayingUtilityControls` passes to
    /// its circles; unbounded outside the row.
    @Entry var playerUtilityCircleCeiling: Double = .infinity
}

extension View {
    func playerUtilityCircleChrome(
        isActive: Bool = false,
        progress: Double? = nil,
        labelIsText: Bool = false
    ) -> some View {
        modifier(PlayerUtilityCircleChrome(isActive: isActive, progress: progress, labelIsText: labelIsText))
    }
}
