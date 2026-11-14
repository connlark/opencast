import OpenCastCore
import SwiftUI

struct IncompleteFeedNotice: View {
    let reason: FeedIncompleteReason
    let isRefreshing: Bool
    let retry: () -> Void
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(FeedCompleteness.partialNotice, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .disabled(isRefreshing)
                Button(action: showDetails) {
                    Label("Details", systemImage: "info.circle")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                if isRefreshing { ProgressView().accessibilityLabel("Loading feed") }
            }
            // The show page puts this notice in its hero's List row, where
            // default-style buttons make the whole row one target that fires
            // both. Borderless buttons take only their labels' 44 pt targets.
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Incomplete Feed Notice")
        .alert("Feed Loading Details", isPresented: $isShowingDetails) {
        } message: { Text(reason.diagnostic) }
    }

    private func showDetails() {
        isShowingDetails = true
    }
}
