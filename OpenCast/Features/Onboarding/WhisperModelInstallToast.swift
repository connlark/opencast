import SwiftUI

struct WhisperModelInstallToast: View {
    static let title = "Tiny Whisper install started"
    static let detail = "Downloading in the background."
    static let accessibilityAnnouncement = "Tiny Whisper model install started. Downloading in the background."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 14) {
            WhisperModelInstallWaveformView(isAnimating: isAnimating, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title)
                    .font(.headline)

                Text(Self.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.yellow)
                .scaleEffect(reduceMotion ? 1 : (isAnimating ? 1.16 : 0.9))
                .opacity(reduceMotion ? 1 : (isAnimating ? 1 : 0.7))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityAnnouncement)
        .accessibilityIdentifier("Tiny Whisper Install Toast")
        .onAppear(perform: startAnimation)
        .onDisappear(perform: stopAnimation)
    }

    private func startAnimation() {
        guard !reduceMotion else {
            return
        }

        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }

    private func stopAnimation() {
        isAnimating = false
    }
}
