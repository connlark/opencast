import SwiftData
import SwiftUI

struct SettingsTranscriptionEngineSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var prefersAppleSpeech = false
    @State private var isConfirmingAppleSpeech = false

    var body: some View {
        Section {
            if appModel.appleSpeechAssets.isTranscriberAvailable {
                Toggle("Use Apple Transcription", isOn: $prefersAppleSpeech)
                    .confirmationDialog(
                        "Use Apple transcription?",
                        isPresented: $isConfirmingAppleSpeech,
                        titleVisibility: .visible
                    ) {
                        Button("Use Apple Transcription", action: enableAppleSpeech)
                        Button("Cancel", role: .cancel, action: cancelAppleSpeechSelection)
                    } message: {
                        Text("Apple transcription runs on-device and only while opencast is open in the foreground. If the app is closed, backgrounded, or the screen locks mid-transcript, the run starts over.")
                    }
            } else {
                LabeledContent {
                    Text("Unavailable")
                } label: {
                    Label("Apple Transcription", systemImage: "mic")
                }
            }

            if let message = appModel.transcriptionEngineSettings.lastErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Engine")
        } footer: {
            HelpFooterLink(title: "How transcription engines work", topicID: HelpTopicID.transcriptionEngines)
        }
        .onChange(of: prefersAppleSpeech) { _, newValue in
            updateAppleSpeechPreference(newValue)
        }
        .onChange(of: appModel.transcriptionEngineSettings.prefersAppleSpeech) { _, storeValue in
            guard prefersAppleSpeech != storeValue else {
                return
            }
            prefersAppleSpeech = storeValue
        }
        .task {
            prefersAppleSpeech = appModel.transcriptionEngineSettings.prefersAppleSpeech
        }
    }

    private func updateAppleSpeechPreference(_ newValue: Bool) {
        let settings = appModel.transcriptionEngineSettings
        guard newValue != settings.prefersAppleSpeech else {
            return
        }

        if newValue, !settings.hasAcknowledgedAppleSpeechNotice {
            isConfirmingAppleSpeech = true
            return
        }

        guard settings.setPrefersAppleSpeech(newValue, modelContext: modelContext) else {
            prefersAppleSpeech = settings.prefersAppleSpeech
            return
        }
    }

    private func enableAppleSpeech() {
        let settings = appModel.transcriptionEngineSettings
        guard settings.setPrefersAppleSpeech(true, modelContext: modelContext) else {
            prefersAppleSpeech = settings.prefersAppleSpeech
            return
        }
    }

    private func cancelAppleSpeechSelection() {
        prefersAppleSpeech = appModel.transcriptionEngineSettings.prefersAppleSpeech
    }
}
