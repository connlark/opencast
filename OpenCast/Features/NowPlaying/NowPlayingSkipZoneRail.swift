import OpenCastPlayback
import SwiftUI

struct NowPlayingSkipZoneRail: View {
    private static let height: CGFloat = 4
    private static let minimumZoneWidth: CGFloat = 2
    private static let stripeSpacing: CGFloat = 6

    let duration: TimeInterval
    let zones: [PlaybackSkipZone]
    let displayOnlyZones: [PlaybackSkipZone]

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Canvas { context, size in
            drawZones(displayOnlyZones, dimmed: true, in: &context, size: size)
            drawZones(zones, dimmed: false, in: &context, size: size)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func drawZones(
        _ zones: [PlaybackSkipZone],
        dimmed: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard duration.isFinite, duration > 0, size.width > 0, size.height > 0 else {
            return
        }

        let fill = Color.red.opacity(dimmed ? 0.26 : 0.72)
        let stripe = Color.white.opacity(dimmed ? 0.35 : 0.75)

        for zone in zones {
            guard let rect = rect(for: zone, size: size) else {
                continue
            }

            let shape = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            context.fill(shape, with: .color(fill))

            if differentiateWithoutColor {
                var stripedContext = context
                stripedContext.clip(to: shape)
                stripedContext.stroke(stripePath(in: rect), with: .color(stripe), lineWidth: 1)
            }
        }
    }

    private func rect(for zone: PlaybackSkipZone, size: CGSize) -> CGRect? {
        let startX = xPosition(for: zone.startTime, width: size.width)
        let endX = xPosition(for: zone.endTime, width: size.width)
        let rawWidth = endX - startX
        guard rawWidth > 0 else {
            return nil
        }

        let visualWidth = min(size.width, max(rawWidth, Self.minimumZoneWidth))
        let x = min(max(0, startX), max(0, size.width - visualWidth))
        return CGRect(x: x, y: 0, width: visualWidth, height: size.height)
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let clampedTime = time.clamped(to: 0...duration)
        return CGFloat(clampedTime / duration) * width
    }

    private func stripePath(in rect: CGRect) -> Path {
        var path = Path()

        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += Self.stripeSpacing
        }

        return path
    }
}

#Preview {
    VStack(spacing: 12) {
        Slider(value: .constant(86), in: 0...600)
        NowPlayingSkipZoneRail(
            duration: 600,
            zones: [
                PlaybackSkipZone(id: 1, startTime: 40, endTime: 65),
                PlaybackSkipZone(id: 2, startTime: 310, endTime: 350)
            ],
            displayOnlyZones: [
                PlaybackSkipZone(id: 3, startTime: 120, endTime: 180),
                PlaybackSkipZone(id: 4, startTime: 470, endTime: 520)
            ]
        )
    }
    .padding()
    .tint(.accentColor)
}
