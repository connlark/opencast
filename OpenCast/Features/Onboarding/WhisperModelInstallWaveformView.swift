import SwiftUI

struct WhisperModelInstallWaveformView: View {
    private static let barHeights: [(base: Double, animated: Double)] = [
        (base: 11, animated: 22),
        (base: 18, animated: 12),
        (base: 14, animated: 26),
        (base: 24, animated: 15),
        (base: 13, animated: 24),
    ]

    let isAnimating: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
                .frame(width: 46, height: 46)
                .scaleEffect(reduceMotion ? 1 : (isAnimating ? 1.08 : 0.94))
                .opacity(reduceMotion ? 0.18 : (isAnimating ? 0.26 : 0.14))

            HStack(alignment: .center, spacing: 3) {
                ForEach(Self.barHeights.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index.isMultiple(of: 2) ? Color.red : Color.teal)
                        .frame(width: 4, height: barHeight(for: Self.barHeights[index]))
                }
            }
            .frame(width: 34, height: 30)
        }
        .frame(width: 48, height: 48)
        .animation(reduceMotion ? .default : .easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: isAnimating)
        .accessibilityHidden(true)
    }

    private func barHeight(for heights: (base: Double, animated: Double)) -> Double {
        guard !reduceMotion else {
            return 16
        }

        return isAnimating ? heights.animated : heights.base
    }
}
