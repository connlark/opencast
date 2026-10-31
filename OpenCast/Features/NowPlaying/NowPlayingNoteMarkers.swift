import SwiftUI

struct NowPlayingNoteMarkers: View {
    let duration: TimeInterval?
    let timestamps: [TimeInterval]

    var body: some View {
        Canvas { context, size in
            // The slider thumb's center travels between these inset endpoints.
            let inset = min(12.0, size.width / 2)
            let width = max(0, size.width - 2 * inset)
            for fraction in Self.fractions(duration: duration, timestamps: timestamps) {
                let x = inset + fraction * width
                let y = size.height / 2
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: y - 3))
                flag.addLine(to: CGPoint(x: x - 4, y: y - 10))
                flag.addLine(to: CGPoint(x: x + 4, y: y - 10))
                flag.closeSubpath()
                context.stroke(flag, with: .color(.primary), lineWidth: 1)
                context.fill(flag, with: .color(.yellow))
            }
        }
    }

    static func fractions(duration: TimeInterval?, timestamps: [TimeInterval]) -> [Double] {
        guard let duration, duration.isFinite, duration > 0 else { return [] }
        return timestamps.compactMap { timestamp in
            guard timestamp.isFinite, timestamp >= 0, timestamp <= duration else { return nil }
            return timestamp / duration
        }
    }
}
