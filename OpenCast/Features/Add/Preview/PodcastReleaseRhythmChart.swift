import SwiftUI

struct PodcastReleaseRhythmChart: View {
    let counts: [Int]
    var ceiling: Int?

    var body: some View {
        let peak = max(ceiling ?? counts.max() ?? 0, 4)

        GeometryReader { proxy in
            let gap = max(2, proxy.size.width * 0.035)
            let slots = Double(max(counts.count, 1))
            let barWidth = max((proxy.size.width - gap * (slots - 1)) / slots, 1)
            let barSpace = max(proxy.size.height - 2, 1)

            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(counts.indices, id: \.self) { index in
                        let count = counts[index]
                        if count > 0 {
                            UnevenRoundedRectangle(
                                topLeadingRadius: min(barWidth / 2, 3),
                                topTrailingRadius: min(barWidth / 2, 3)
                            )
                            .fill(.tint)
                            .frame(
                                width: barWidth,
                                height: max(barSpace * Double(min(count, peak)) / Double(peak), 3)
                            )
                        } else {
                            UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1)
                                .fill(.quaternary)
                                .frame(width: barWidth, height: 2)
                        }
                    }
                }
                .padding(.bottom, 2)

                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .accessibilityElement()
        .accessibilityLabel("Episodes per month")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let total = counts.reduce(0, +)
        guard total > 0 else {
            return "No episodes in the last 12 months"
        }
        return "\(total.formatted()) \(total == 1 ? "episode" : "episodes") in the last 12 months"
    }
}
