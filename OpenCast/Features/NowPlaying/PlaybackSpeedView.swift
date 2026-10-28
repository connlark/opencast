import OpenCastPlayback
import SwiftData
import SwiftUI

struct PlaybackSpeedView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var errorMessage: String?

    /// The playing episode's show when it is subscribed; a one-off play has
    /// no show to give a speed of its own.
    private var subscribedPodcastID: String? {
        guard let podcastID = appModel.playback.currentEpisode?.podcastID.rawValue,
              appModel.library.isActivelySubscribed(to: podcastID)
        else {
            return nil
        }
        return podcastID
    }

    /// Read from the library's saved record, never cached: a speed another
    /// device cleared reads as off, and a failed save leaves it where it was.
    private var isCustomForShow: Bool {
        subscribedPodcastID.flatMap(appModel.library.podcastPlaybackRateOverride(forPodcastID:)) != nil
    }

    private var customForShowBinding: Binding<Bool> {
        Binding(get: { isCustomForShow }, set: { setCustomForShow($0) })
    }

    var body: some View {
        NavigationStack {
            List {
                if subscribedPodcastID != nil {
                    Section {
                        Toggle("Custom for This Show", isOn: customForShowBinding)
                            .accessibilityIdentifier("playback-speed-custom-for-show-toggle")
                    }
                }

                Section {
                    ForEach(PlaybackRateSteps.steps, id: \.self) { speed in
                        Button {
                            select(speed)
                        } label: {
                            HStack {
                                Text(speed.formattedSpeed)
                                Spacer()
                                if appModel.playback.rate == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    if isCustomForShow, let showTitle = appModel.playback.currentEpisode?.podcastTitle {
                        Text("Speed for \(showTitle)")
                    }
                } footer: {
                    if isCustomForShow {
                        Text("This show has its own speed. Other shows play at \(appModel.playbackSettings.globalPlaybackRate.formattedSpeed).")
                    }
                }
            }
            .navigationTitle("Speed")
            .sensoryFeedback(.selection, trigger: appModel.playback.rate)
            .alert("Couldn’t Change Speed", item: $errorMessage) { _ in
            } message: { message in
                Text(message)
            }
        }
    }

    /// On, the show takes the speed playing now, so nothing audible changes;
    /// off, it returns to the global speed at once.
    private func setCustomForShow(_ isOn: Bool) {
        guard let subscribedPodcastID else {
            return
        }
        let didSave = appModel.setPodcastPlaybackRateOverride(
            isOn ? appModel.playback.rate : nil,
            feedURL: subscribedPodcastID,
            modelContext: modelContext
        )
        if !didSave {
            // Shown here; left on the library it would raise the root
            // Library alert as well.
            errorMessage = appModel.library.lastErrorMessage
                ?? "This show’s speed could not be saved."
            appModel.library.clearLastError()
        }
    }

    private func select(_ speed: Float) {
        if appModel.setPlaybackRate(speed, modelContext: modelContext) {
            dismiss()
        } else {
            errorMessage = appModel.playbackSettings.lastErrorMessage
                ?? "Playback speed could not be saved."
            appModel.playbackSettings.clearLastError()
        }
    }
}
