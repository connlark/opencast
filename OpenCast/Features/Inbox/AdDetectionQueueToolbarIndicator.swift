import SwiftUI

/// Compact determinate progress indicator for the Inbox toolbar. Visible
/// whenever the ad-detection queue is non-idle; after a drain finishes it
/// shows a brief completion state, then hides. State changes use gentle
/// fades without attention-seeking motion.
struct AdDetectionQueueToolbarIndicator: View {
    static let accessibilityIdentifier = "Ad Detection Queue Indicator"

    let indicator: AdDetectionQueuePresentation.Indicator
    let accessibilityValue: String
    let onOpen: () -> Void

    @State private var hidesFinishedState = false

    var body: some View {
        if isVisible {
            Button(action: onOpen) {
                Label {
                    Text("Ad Detection Queue")
                } icon: {
                    icon
                }
            }
            .labelStyle(.iconOnly)
            .tint(hasFailures ? .orange : nil)
            .accessibilityLabel("Ad Detection Queue")
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: indicator)
            .task(id: indicator) {
                hidesFinishedState = false
                guard case .finished = indicator else {
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(4))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                hidesFinishedState = true
            }
        }
    }

    private var isVisible: Bool {
        switch indicator {
        case .hidden:
            false
        case .finished:
            !hidesFinishedState
        case .running, .paused:
            true
        }
    }

    private var hasFailures: Bool {
        switch indicator {
        case .hidden:
            false
        case .running(_, let hasFailures), .paused(let hasFailures), .finished(let hasFailures):
            hasFailures
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch indicator {
        case .hidden:
            EmptyView()
        case .running(let fractionCompleted, _):
            progressRing(fractionCompleted: fractionCompleted)
        case .paused:
            Image(systemName: "pause.circle")
        case .finished:
            Image(systemName: "checkmark.circle")
        }
    }

    private func progressRing(fractionCompleted: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fractionCompleted)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 17, height: 17)
        .animation(.easeOut(duration: 0.2), value: fractionCompleted)
    }
}
