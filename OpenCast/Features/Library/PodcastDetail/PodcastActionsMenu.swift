import SwiftData
import SwiftUI

struct PodcastActionsMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let subscription: SubscriptionRecord
    let podcast: PodcastCacheSnapshot?
    let isRefreshing: Bool
    let unplayedEpisodeCount: Int
    let downloadCount: Int
    let onSearch: () -> Void
    let adAutoDetectBinding: Binding<Bool>
    @Binding var isConfirmingAdAutoDetect: Bool
    @Binding var isConfirmingMarkAllPlayed: Bool
    @Binding var isConfirmingDeleteAllDownloads: Bool
    @Binding var isConfirmingUnsubscribe: Bool
    @State private var stateChangeFeedback = 0
    @State private var unsubscribeAlertTitle = ""
    @State private var unsubscribeAlertMessage: String?
    @State private var dismissesAfterUnsubscribeAlert = false

    private var websiteURL: URL? {
        podcast?.websiteURL.flatMap(URL.init(string:))
    }

    private var shareURL: URL? {
        websiteURL ?? URL(string: subscription.feedURL)
    }

    var body: some View {
        Menu {
            Section {
                Button("Search", systemImage: "magnifyingglass", action: onSearch)

                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(isRefreshing)

                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                if let websiteURL {
                    Link(destination: websiteURL) {
                        Label("Visit Website", systemImage: "safari")
                    }
                }
            }

            Section {
                Toggle(
                    "Automatically Detect Ads",
                    systemImage: "megaphone",
                    isOn: adAutoDetectBinding
                )
            }

            Section {
                Button("Mark All Played", systemImage: "checkmark.circle", action: confirmMarkAllPlayed)
                    .disabled(unplayedEpisodeCount == 0)

                Button(
                    "Delete All Downloads",
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmDeleteAllDownloads
                )
                .disabled(downloadCount == 0)

                Button(
                    "Unsubscribe",
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmUnsubscribe
                )
            }
        } label: {
            Label("Podcast Actions", systemImage: "ellipsis.circle")
        }
        .confirmationDialog(
            "Automatically detect ads?",
            isPresented: $isConfirmingAdAutoDetect,
            titleVisibility: .visible
        ) {
            Button("Turn On", action: enableAdAutoDetect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Episodes of this show will be analyzed for ads when you play them.")
        }
        .confirmationDialog(
            "Mark every episode as played?",
            isPresented: $isConfirmingMarkAllPlayed,
            titleVisibility: .visible
        ) {
            Button("Mark All Played", action: markAllPlayed)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Listening progress for every episode in this podcast will be completed.")
        }
        .confirmationDialog(
            "Delete all downloads for this podcast?",
            isPresented: $isConfirmingDeleteAllDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive, action: deleteAllDownloads)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded audio for this podcast will be removed from this device.")
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription.title)?",
            isPresented: $isConfirmingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive, action: unsubscribe)
            Button("Unsubscribe & Clear History", role: .destructive, action: unsubscribeAndClearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads and cached episodes for this podcast will be removed. Listening history is kept unless you clear it.")
        }
        .sensoryFeedback(.success, trigger: stateChangeFeedback)
        // Alert has no item overload for a non-Identifiable String.
        .alert(
            unsubscribeAlertTitle,
            isPresented: Binding(
                get: { unsubscribeAlertMessage != nil },
                set: { if !$0 { unsubscribeAlertMessage = nil } }
            ),
            presenting: unsubscribeAlertMessage
        ) { _ in
            Button("OK") {
                if dismissesAfterUnsubscribeAlert {
                    dismiss()
                }
            }
        } message: { message in
            Text(message)
        }
    }

    private func refresh() {
        Task {
            await appModel.library.refresh(feedURL: subscription.feedURL, modelContext: modelContext)
        }
    }

    private func enableAdAutoDetect() {
        appModel.library.setAdAutoDetectEnabled(
            true,
            feedURL: subscription.feedURL,
            modelContext: modelContext
        )
    }

    private func confirmMarkAllPlayed() {
        isConfirmingMarkAllPlayed = true
    }

    private func markAllPlayed() {
        appModel.markAllEpisodesPlayed(
            forPodcastID: subscription.feedURL,
            modelContext: modelContext
        )
        stateChangeFeedback += 1
    }

    private func confirmDeleteAllDownloads() {
        isConfirmingDeleteAllDownloads = true
    }

    private func deleteAllDownloads() {
        appModel.deleteDownloads(
            forPodcastID: subscription.feedURL,
            modelContext: modelContext
        )
    }

    private func confirmUnsubscribe() {
        isConfirmingUnsubscribe = true
    }

    private func unsubscribe() {
        unsubscribe(clearListeningHistory: false)
    }

    private func unsubscribeAndClearHistory() {
        unsubscribe(clearListeningHistory: true)
    }

    private func unsubscribe(clearListeningHistory: Bool) {
        Task {
            let outcome = await appModel.unsubscribe(
                feedURL: subscription.feedURL,
                modelContext: modelContext,
                clearListeningHistory: clearListeningHistory
            )
            let decision = PodcastUnsubscribePresentationDecision.make(outcome: outcome)
            if decision.emitsSuccessFeedback {
                stateChangeFeedback += 1
            }
            if decision.dismissesImmediately {
                dismiss()
            } else if let title = decision.alertTitle,
                      let message = decision.alertMessage {
                dismissesAfterUnsubscribeAlert = decision.dismissesAfterAlert
                unsubscribeAlertTitle = title
                unsubscribeAlertMessage = message
            }
        }
    }
}
