import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Ad Skipping › Skip Sound: None, the sounds this build carries
/// and the listener's own. A tap chooses a sound and plays it once, so the
/// list can be auditioned without leaving it.
struct SettingsSkipSoundView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var sounds: [SkipSound] = []
    @State private var isImporting = false
    @State private var importMessage: String?

    var body: some View {
        let settings = appModel.playbackSettings
        Form {
            Section {
                SkipSoundOptionRow(sound: nil, onChoose: clearImportMessage)

                ForEach(sounds) { sound in
                    SkipSoundOptionRow(sound: sound, onChoose: clearImportMessage)
                }

                if let customSound = settings.customSkipSound {
                    SkipSoundOptionRow(sound: customSound.skipSound, onChoose: clearImportMessage)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive, action: removeCustomSound)
                        }
                }

                Button(settings.customSkipSound == nil ? "Add Sound…" : "Replace Sound…", action: showImporter)
                    .accessibilityIdentifier("skip-sound-import")

                if let message = importMessage ?? settings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if settings.customSkipSound != nil {
                    Text("Your own sound plays at the volume it was recorded at.")
                }
            }
        }
        .settingsSubscreen(title: "Skip Sound")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio], onCompletion: importChosenFile)
        // The bundle and the listener's own sound are read only once the
        // picker opens.
        .task {
            sounds = SkipSoundCatalog.availableSounds(in: .main)
            appModel.loadCustomSkipSound(modelContext: modelContext)
        }
    }

    private func showImporter() {
        importMessage = nil
        isImporting = true
    }

    private func clearImportMessage() {
        importMessage = nil
    }

    private func importChosenFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            Task { await importSound(from: url) }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                importMessage = error.localizedDescription
            }
        }
    }

    private func importSound(from url: URL) async {
        do {
            try await appModel.importCustomSkipSound(from: url, modelContext: modelContext)
        } catch {
            importMessage = error.message
        }
    }

    private func removeCustomSound() {
        importMessage = nil
        appModel.removeCustomSkipSound(modelContext: modelContext)
    }
}
