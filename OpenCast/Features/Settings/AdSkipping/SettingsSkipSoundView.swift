import SwiftUI

/// Settings › Ad Skipping › Skip Sound: None and the sounds this build
/// carries. A tap chooses a sound and plays it once, so the list can be
/// auditioned without leaving it.
struct SettingsSkipSoundView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var sounds: [SkipSound] = []

    var body: some View {
        Form {
            Section {
                SkipSoundOptionRow(sound: nil)

                ForEach(sounds) { sound in
                    SkipSoundOptionRow(sound: sound)
                }

                if let message = appModel.playbackSettings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .settingsSubscreen(title: "Skip Sound")
        // The bundle is searched for the whole list only once the picker opens.
        .task {
            sounds = SkipSoundCatalog.availableSounds(in: .main)
        }
    }
}
