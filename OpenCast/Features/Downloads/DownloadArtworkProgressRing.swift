import SwiftUI

struct DownloadArtworkProgressRing: View {
    let fractionCompleted: Double?
    let isPaused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))

            Group {
                if isPaused {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.7), lineWidth: 3)
                        Image(systemName: "pause.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                } else if let fractionCompleted {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.35), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1, fractionCompleted)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .padding(9)
        }
        .clipShape(.rect(cornerRadius: 8))
        .animation(.easeOut(duration: 0.2), value: fractionCompleted)
        .accessibilityHidden(true)
    }
}
