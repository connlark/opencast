import SwiftUI

struct LibraryEmptyStateView: View {
    let syncActivity: SyncLibraryActivity
    let isSubscribingSample: Bool
    let sampleSubscriptionErrorMessage: String?
    let onAdd: () -> Void
    let onSubscribeSample: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            if syncActivity.shouldDisplay {
                SyncLibraryActivityView(activity: syncActivity)
                    .padding(.horizontal)
            }

            if !syncActivity.showsProgress {
                ContentUnavailableView {
                    Label("No Subscriptions", systemImage: "books.vertical")
                } description: {
                    Text("Add a podcast by search or RSS, or start with This American Life.")
                }

                VStack(spacing: 12) {
                    Button(action: onAdd) {
                        Text("Add Podcast")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("Library Empty Add Podcast")

                    if isSubscribingSample {
                        ProgressView("Adding This American Life")
                    } else {
                        Button(action: onSubscribeSample) {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                Text("Try This American Life")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .frame(maxWidth: 280)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("Library Empty Try This American Life")
                    }

                    if let sampleSubscriptionErrorMessage {
                        Label(sampleSubscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
