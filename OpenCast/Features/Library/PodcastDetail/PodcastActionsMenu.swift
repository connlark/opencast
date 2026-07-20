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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached episodes, progress, refresh logs, and local downloads for this podcast will be removed.")
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
        Task {
            await appModel.unsubscribe(feedURL: subscription.feedURL, modelContext: modelContext)
            dismiss()
        }
    }
}
