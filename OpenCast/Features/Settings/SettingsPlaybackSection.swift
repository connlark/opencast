import SwiftUI

struct SettingsPlaybackSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            Picker("Voice Boost", selection: voiceBoostModeBinding) {
                ForEach(VoiceBoostMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Voice Boost")
            .accessibilityValue(appModel.playbackSettings.voiceBoostMode.fullTitle)

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
            }

            if let message = appModel.playbackSettings.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Voice Boost is on by default. Per Episode lets the Now Playing card control the current episode only.")
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
}
