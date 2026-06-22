import SwiftUI

struct EpisodeSearchLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    let mode: EpisodeSearchMode

    private var title: String {
        switch mode {
        case .episodes:
            "Searching Episodes"
        case .fullText:
            "Searching Full Text"
        }
    }

    private var message: String {
        switch mode {
        case .episodes:
            "Checking episode titles and podcast names."
        case .fullText:
            "Scanning summaries and show notes."
        }
    }

    private var pulseOpacity: Double {
        reduceMotion ? 0.42 : (isPulsing ? 0.22 : 0.58)
    }

    private var pulseScale: Double {
        reduceMotion ? 1 : (isPulsing ? 1.12 : 0.86)
    }

    private var pulseAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.16))
                Circle()
                    .stroke(.tint.opacity(0.28), lineWidth: 1)
                Circle()
                    .stroke(Color.primary.opacity(pulseOpacity), lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulseScale)
                    .animation(pulseAnimation, value: isPulsing)
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .bold()
                    .foregroundStyle(.primary)
            }
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                isPulsing = !reduceMotion
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Episode Search Loading") {
    List {
        EpisodeSearchLoadingView(mode: .episodes)
    }
}

#Preview("Full Text Search Loading") {
    List {
        EpisodeSearchLoadingView(mode: .fullText)
    }
}
