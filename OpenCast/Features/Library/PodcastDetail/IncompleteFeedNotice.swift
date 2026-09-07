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
                Button("Retry", systemImage: "arrow.clockwise") {
                    retry()
                }
                .disabled(isRefreshing)
                .frame(minHeight: 44)
                Button("Details", systemImage: "info.circle", action: showDetails)
                    .frame(minHeight: 44)
                if isRefreshing { ProgressView().accessibilityLabel("Loading feed") }
            }
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
