import StateReporting

final class PerformanceStateReporter {
    static let shared = PerformanceStateReporter()
    private var labels: [PerformanceState.Domain: String] = [:]
    private let publish: (PerformanceState) -> Void
    private(set) var transitionCount = 0

    init(publish: @escaping (PerformanceState) -> Void = { state in
        StateReporter<Never, Never>.reporter(for: state.domain.identifier).reportTransition(to: state.label)
    }) {
        self.publish = publish
    }

    func transition(_ domain: PerformanceState.Domain, to label: String) {
        guard labels[domain] != label, let state = PerformanceState(domain: domain, label: label) else { return }
        labels[domain] = label
        transitionCount += 1
        publish(state)
    }

    func nowPlayingMarker(_ marker: String) {
        switch marker {
        case "present-requested", "overlay-mounted", "card-animate-start": transition(.nowPlaying, to: "presenting")
        case "card-settled", "dismiss-drag-ended":
            if labels[.nowPlaying] != "hidden" { transition(.nowPlaying, to: "visible") }
        case "dismiss-requested", "dismiss-animate-start", "dismiss-drag-start": transition(.nowPlaying, to: "dismissing")
        case "dismiss-completed", "overlay-unmounted", "card-dismissed": transition(.nowPlaying, to: "hidden")
        default: break
        }
    }
}
