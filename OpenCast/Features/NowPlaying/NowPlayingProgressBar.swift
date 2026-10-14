import OpenCastPlayback
import SwiftUI

struct NowPlayingProgressBar: View {
    private static let idleHeight: CGFloat = 7
    private static let activeHeight: CGFloat = 14
    private static let touchHeight: CGFloat = 44
    private static let separatorWidth: CGFloat = 1.5
    private static let minimumZoneWidth: CGFloat = 2
    private static let stripeSpacing: CGFloat = 6

    let duration: TimeInterval
    let position: TimeInterval
    let chapterBoundaries: [TimeInterval]
    let zones: [PlaybackSkipZone]
    let displayOnlyZones: [PlaybackSkipZone]
    let onScrubBegan: () -> Void
    let onScrub: (TimeInterval) -> Void
    let onScrubEnded: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: DragSample?

    private struct DragSample: Equatable {
        var start: TimeInterval
        var current: TimeInterval
    }

    private var isScrubbing: Bool {
        drag != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: isScrubbing ? Self.activeHeight : Self.idleHeight)
            .frame(width: width, height: Self.touchHeight)
            .contentShape(.rect)
            .gesture(scrubGesture(width: width))
        }
        .frame(height: Self.touchHeight)
        .animation(reduceMotion ? nil : .spring(duration: 0.22), value: isScrubbing)
        .onChange(of: drag) { previous, current in
            if previous == nil, current != nil {
                onScrubBegan()
            }
            if let current {
                onScrub(current.current)
            } else if previous != nil {
                onScrubEnded()
            }
        }
    }

    // MARK: - Gesture

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($drag) { value, state, _ in
                let start = state?.start ?? position
                let delta = width > 0 ? TimeInterval(value.translation.width / width) * duration : 0
                state = DragSample(start: start, current: (start + delta).clamped(to: 0...duration))
            }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let trackShape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)

        context.fill(trackShape, with: .color(.primary.opacity(0.28)))

        var filled = context
        filled.clip(to: trackShape)
        let playheadX = xPosition(for: position, width: size.width)
        filled.fill(
            Path(CGRect(x: 0, y: 0, width: playheadX, height: size.height)),
            with: .color(.accentColor)
        )

        drawZones(displayOnlyZones, dimmed: true, clippedTo: trackShape, in: context, size: size)
        drawZones(zones, dimmed: false, clippedTo: trackShape, in: context, size: size)
        drawChapterSeparators(in: context, size: size)
    }

    private func drawChapterSeparators(in context: GraphicsContext, size: CGSize) {
        var cut = context
        cut.blendMode = .destinationOut
        for boundary in chapterBoundaries where boundary > 0 && boundary < duration {
            let x = xPosition(for: boundary, width: size.width) - Self.separatorWidth / 2
            guard x > Self.separatorWidth, x < size.width - Self.separatorWidth * 2 else {
                continue
            }
            cut.fill(Path(CGRect(x: x, y: 0, width: Self.separatorWidth, height: size.height)), with: .color(.black))
        }
    }

    private func drawZones(
        _ zones: [PlaybackSkipZone],
        dimmed: Bool,
        clippedTo trackShape: Path,
        in context: GraphicsContext,
        size: CGSize
    ) {
        guard !zones.isEmpty else {
            return
        }
        var zoneContext = context
        zoneContext.clip(to: trackShape)
        let fill = Color.red.opacity(dimmed ? 0.3 : 0.75)
        let stripe = Color.white.opacity(dimmed ? 0.35 : 0.75)

        for zone in zones {
            let startX = xPosition(for: zone.startTime, width: size.width)
            let endX = xPosition(for: zone.endTime, width: size.width)
            guard endX > startX else {
                continue
            }
            let rect = CGRect(x: startX, y: 0, width: max(endX - startX, Self.minimumZoneWidth), height: size.height)
            zoneContext.fill(Path(rect), with: .color(fill))
            if differentiateWithoutColor {
                var striped = zoneContext
                striped.clip(to: Path(rect))
                striped.stroke(stripePath(in: rect), with: .color(stripe), lineWidth: 1)
            }
        }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else {
            return 0
        }
        return CGFloat(time.clamped(to: 0...duration) / duration) * width
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
    VStack(spacing: 32) {
        NowPlayingProgressBar(
            duration: 3_600,
            position: 1_250,
            chapterBoundaries: [420, 900, 1_700, 2_600],
            zones: [PlaybackSkipZone(id: 1, startTime: 950, endTime: 1_080)],
            displayOnlyZones: [PlaybackSkipZone(id: 2, startTime: 2_900, endTime: 3_000)],
            onScrubBegan: {},
            onScrub: { _ in },
            onScrubEnded: {}
        )
        NowPlayingProgressBar(
            duration: 600,
            position: 90,
            chapterBoundaries: [],
            zones: [],
            displayOnlyZones: [],
            onScrubBegan: {},
            onScrub: { _ in },
            onScrubEnded: {}
        )
    }
    .padding(24)
}
