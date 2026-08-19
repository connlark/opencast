import SwiftData
import SwiftUI

struct PodcastPlaybackSettingsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let feedURL: String

    @State private var introText = "0:00"
    @State private var outroText = "0:00"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PodcastPlaybackSkipRow(
                        title: "Skip Intro",
                        fieldAccessibilityIdentifier: "Skip Intro Duration",
                        text: $introText,
                        onDecrease: decreaseIntro,
                        onIncrease: increaseIntro
                    )

                    PodcastPlaybackSkipRow(
                        title: "Skip Outro",
                        fieldAccessibilityIdentifier: "Skip Outro Duration",
                        text: $outroText,
                        onDecrease: decreaseOutro,
                        onIncrease: increaseOutro
                    )
                } footer: {
                    Text("Enter m:ss or h:mm:ss. Changes apply the next time an episode loads or replays.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("Podcast Playback Settings Error")
                    }
                }

                Section {
                    Button("Reset Both", systemImage: "arrow.counterclockwise", role: .destructive, action: resetBoth)
                }
            }
            .onChange(of: introText) { _, _ in
                errorMessage = nil
            }
            .onChange(of: outroText) { _, _ in
                errorMessage = nil
            }
            .navigationTitle("Skip Intro & Outro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear(perform: loadSettings)
        }
    }

    private func loadSettings() {
        let settings = appModel.library.podcastPlaybackSkipSettings(forPodcastID: feedURL)
        introText = PodcastPlaybackDurationText.format(settings.skipIntroSeconds)
        outroText = PodcastPlaybackDurationText.format(settings.skipOutroSeconds)
    }

    private func decreaseIntro() {
        adjust(&introText, by: -5)
    }

    private func increaseIntro() {
        adjust(&introText, by: 5)
    }

    private func decreaseOutro() {
        adjust(&outroText, by: -5)
    }

    private func increaseOutro() {
        adjust(&outroText, by: 5)
    }

    private func adjust(_ text: inout String, by adjustment: TimeInterval) {
        guard let seconds = PodcastPlaybackDurationText.parse(text) else {
            errorMessage = "Enter each duration as m:ss or h:mm:ss."
            return
        }
        text = PodcastPlaybackDurationText.format(max(0, seconds + adjustment))
        errorMessage = nil
    }

    private func resetBoth() {
        introText = PodcastPlaybackDurationText.format(0)
        outroText = PodcastPlaybackDurationText.format(0)
        errorMessage = nil
    }

    private func save() {
        guard let skipIntroSeconds = PodcastPlaybackDurationText.parse(introText),
              let skipOutroSeconds = PodcastPlaybackDurationText.parse(outroText)
        else {
            errorMessage = "Enter each duration as m:ss or h:mm:ss."
            return
        }

        let didSave = appModel.library.setPodcastPlaybackSkipSettings(
            PodcastPlaybackSkipSettings(
                skipIntroSeconds: skipIntroSeconds,
                skipOutroSeconds: skipOutroSeconds
            ),
            feedURL: feedURL,
            modelContext: modelContext
        )
        guard didSave else {
            errorMessage = appModel.library.lastErrorMessage
                ?? "Unable to save intro and outro skips."
            return
        }
        dismiss()
    }
}
