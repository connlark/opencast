import SwiftUI

struct EpisodeProgressBarView: View {
    let fractionCompleted: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.22))

                Capsule()
                    .fill(.tint)
                    .frame(width: proxy.size.width * CGFloat(fractionCompleted.clamped01))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
