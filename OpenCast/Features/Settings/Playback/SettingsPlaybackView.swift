import SwiftData
import SwiftUI

struct SettingsPlaybackView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Form {
            Section {
                Picker("Voice Boost", selection: voiceBoostModeBinding) {
                    ForEach(VoiceBoostMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Voice Boost")
                .accessibilityValue(appModel.playbackSettings.voiceBoostMode.fullTitle)
            } header: {
                Text("Voice Boost")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lifts quiet voices and evens out volume.")
                    HelpFooterLink(title: "How Voice Boost works", topicID: HelpTopicID.voiceBoost)
                }
            }

            Section("Skipping") {
                LabeledContent("Skip Back") {
                    Picker("Skip Back", selection: skipBackwardBinding) {
                        ForEach(PlaybackSkipIntervalOption.allCases) { option in
                            Label(option.label, systemImage: option.backwardSystemImage)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                LabeledContent("Skip Forward") {
                    Picker("Skip Forward", selection: skipForwardBinding) {
                        ForEach(PlaybackSkipIntervalOption.allCases) { option in
                            Label(option.label, systemImage: option.forwardSystemImage)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("playback-skip-forward-picker")
                }

                if let message = appModel.playbackSettings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Sleep Timer") {
                NavigationLink("Presets", value: AppRoute.settings(.sleepTimer))
                    .accessibilityIdentifier("playback-sleep-timer-presets-row")
            }

            Section {
                Toggle("Show Note Button", isOn: privateNoteButtonsBinding)
                    .accessibilityIdentifier("playback-private-notes-toggle")
            } header: {
                Text("Private Notes")
            } footer: {
                Text("Adds a note button to Now Playing; notes stay on this device.")
            }

            Section {
                Toggle("Tap to Play", isOn: tapToPlayBinding)
                    .accessibilityIdentifier("playback-tap-to-play-toggle")
            } header: {
                Text("Episodes")
            } footer: {
                Text("When off, tapping an episode opens its details and the play button beside it starts playback.")
            }

            Section {
                NavigationLink(value: AppRoute.settings(.autoAddToUpNext)) {
                    LabeledContent("Auto Add to Up Next", value: autoAddToUpNextSummary)
                }
                .accessibilityIdentifier("playback-auto-add-to-up-next-row")

                Toggle("Requeue Interrupted Episode", isOn: requeueInterruptedEpisodeBinding)
                    .accessibilityIdentifier("playback-requeue-interrupted-episode-toggle")
            } header: {
                Text("Up Next")
            } footer: {
                Text("When on, starting another episode puts the one playing at the head of Up Next so it resumes afterward.")
            }
        }
        .settingsSubscreen(title: "Playback")
    }

    /// Off, or how many shows add their new episodes.
    private var autoAddToUpNextSummary: String {
        switch appModel.library.upNextAutoAddPodcastIDs.count {
        case 0:
            "Off"
        case 1:
            "1 show"
        case let count:
            "\(count.formatted()) shows"
        }
    }

    private var voiceBoostModeBinding: Binding<VoiceBoostMode> {
        Binding {
            appModel.playbackSettings.voiceBoostMode
        } set: { mode in
            _ = appModel.setVoiceBoostMode(mode, modelContext: modelContext)
        }
    }

    private var skipBackwardBinding: Binding<PlaybackSkipIntervalOption> {
        Binding {
            appModel.playbackSettings.skipBackwardOption
        } set: { option in
            _ = appModel.setSkipBackwardOption(option, modelContext: modelContext)
        }
    }

    private var skipForwardBinding: Binding<PlaybackSkipIntervalOption> {
        Binding {
            appModel.playbackSettings.skipForwardOption
        } set: { option in
            _ = appModel.setSkipForwardOption(option, modelContext: modelContext)
        }
    }

    private var privateNoteButtonsBinding: Binding<Bool> {
        Binding {
            appModel.playbackSettings.showsPrivateNoteButtons
        } set: { isEnabled in
            _ = appModel.setPrivateNoteButtonsEnabled(isEnabled, modelContext: modelContext)
        }
    }

    private var tapToPlayBinding: Binding<Bool> {
        Binding {
            appModel.playbackSettings.isTapToPlayEnabled
        } set: { isEnabled in
            _ = appModel.setTapToPlayEnabled(isEnabled, modelContext: modelContext)
        }
    }

    private var requeueInterruptedEpisodeBinding: Binding<Bool> {
        Binding {
            appModel.playbackSettings.isRequeueInterruptedEpisodeEnabled
        } set: { isEnabled in
            _ = appModel.setRequeueInterruptedEpisodeEnabled(isEnabled, modelContext: modelContext)
        }
    }
}
