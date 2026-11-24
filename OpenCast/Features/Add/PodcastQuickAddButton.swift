import SwiftUI

struct PodcastQuickAddButton: View {
    enum Phase {
        case add
        case adding
        case added
    }

    @ScaledMetric(relativeTo: .body) private var circleDiameter = 36.0

    let phase: Phase
    let showTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                icon
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: circleDiameter, height: circleDiameter)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch phase {
        case .add: "Subscribe to \(showTitle)"
        case .adding: "Subscribing to \(showTitle)"
        case .added: "\(showTitle), In Library"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .add:
            Image(systemName: "plus")
                .foregroundStyle(.tint)
        case .adding:
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)
        case .added:
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        }
    }
}
