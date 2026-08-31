import OpenCastTranscription
import SwiftUI

struct SettingsTranscriptionModelSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    /// The Fast/Accurate model picker is a diagnostics-only affordance; the
    /// product path pins whisper tiny.
    var includesModelPicker = false
    var sectionTitle = "Transcription"

    @State private var prefersAppleSpeech = false
    @State private var isConfirmingAppleSpeech = false
    @State private var selectedChoice = TranscriptionModelChoice.defaultChoice
    @State private var isConfirmingInstall = false
    @State private var isConfirmingRepair = false
    @State private var isConfirmingDelete = false
    @State private var loadedModelState = TranscriptionModelState.unknown

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
                        Text("Apple transcription runs on-device and only while OpenCast is open in the foreground. The screen stays awake while it runs. If the app is closed, backgrounded, or the screen is locked mid-transcript, the run stops and starts over from the beginning. When a language or device isn't supported, the Whisper model is used automatically instead.")
                    }
            }

            if let message = appModel.transcriptionEngineSettings.lastErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if includesModelPicker {
                Picker("Transcript Model", selection: $selectedChoice) {
                    ForEach(TranscriptionModelChoice.allCases) { choice in
                        Text(choice.title)
                            .tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedChoice.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            statusRow

            switch modelState {
            case .unknown, .notInstalled, .failed:
                Button(installButtonTitle, systemImage: "arrow.down.circle", action: confirmInstall)
            case .checking:
                ProgressView("Checking Model")
            case .installing(let progress):
                SettingsTranscriptionModelInstallProgressView(progress: progress)
                Button("Cancel Install", systemImage: "xmark.circle", role: .cancel, action: cancelInstall)
            case .installed:
                Button("Check Model", systemImage: "arrow.clockwise", action: checkModel)
                Button(deleteButtonTitle, systemImage: "trash", role: .destructive, action: confirmDelete)
            case .repairAvailable:
                Button("Repair Model", systemImage: "wrench.and.screwdriver", action: confirmRepair)
                Button(deleteButtonTitle, systemImage: "trash", role: .destructive, action: confirmDelete)
            case .deleting:
                ProgressView("Deleting Model")
            }
        } header: {
            Text(sectionTitle)
        } footer: {
            Text(footerText)
        }
        .onChange(of: selectedChoice) { _, newChoice in
            updateSelectedChoice(newChoice)
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
        .onChange(of: appModel.transcriptionModels.selectedChoice) { _, storeChoice in
            guard selectedChoice != storeChoice else {
                return
            }
            selectedChoice = storeChoice
        }
        .confirmationDialog(
            installConfirmationTitle,
            isPresented: $isConfirmingInstall,
            titleVisibility: .visible
        ) {
            Button(installButtonTitle, action: installModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installConfirmationMessage)
        }
        .confirmationDialog(
            "Repair speech model?",
            isPresented: $isConfirmingRepair,
            titleVisibility: .visible
        ) {
            Button("Repair Model", action: repairModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The installed receipt does not match the signed manifest. The model will be reinstalled.")
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive, action: deleteModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed transcripts stay on this device. New \(selectedChoice.title) transcripts require reinstalling this model.")
        }
        .task {
            prefersAppleSpeech = appModel.transcriptionEngineSettings.prefersAppleSpeech
            selectedChoice = appModel.transcriptionModels.selectedChoice
            let choice = selectedChoice
            let loadedState = await Self.loadModelState(
                modelIdentifier: choice.model.rawValue,
                version: choice.defaultVersion
            )
            guard !Task.isCancelled,
                  choice == appModel.transcriptionModels.selectedChoice else {
                return
            }
            loadedModelState = loadedState
        }
    }

    private var footerText: String {
        if prefersAppleSpeech {
            return "Apple transcription is used when available. The tiny English Whisper model stays installed as the automatic fallback and stays on this device."
        }
        if includesModelPicker {
            return "Fast downloads the tiny English model. Accurate downloads the large-v3 model. Both stay on this device."
        }
        return "The tiny English Whisper model powers transcription on this device and stays on this device."
    }

    private var statusRow: some View {
        LabeledContent {
            Text(statusText)
        } label: {
            Label("Status", systemImage: statusSystemImage)
        }
    }

    private var modelState: TranscriptionModelState {
        if case .unknown = appModel.transcriptionModels.state {
            loadedModelState
        } else {
            appModel.transcriptionModels.state
        }
    }

    private var statusText: String {
        if case .failed(let message) = modelState {
            return message
        }

        return switch modelState {
        case .unknown:
            "Unknown"
        case .notInstalled:
            "Not Installed"
        case .checking:
            "Checking"
        case .installing(let progress):
            "Installing, \(byteCount(progress.completedByteCount)) of \(byteCount(progress.totalByteCount))"
        case .installed(let summary):
            "Installed, \(byteCount(summary.totalByteCount))"
        case .repairAvailable:
            "Repair Required"
        case .deleting:
            "Deleting"
        case .failed(let message):
            message
        }
    }

    private var statusSystemImage: String {
        if case .failed = modelState {
            return "exclamationmark.triangle.fill"
        }

        return switch modelState {
        case .installed:
            "checkmark.circle.fill"
        case .repairAvailable, .failed:
            "exclamationmark.triangle.fill"
        case .installing, .checking, .deleting:
            "clock"
        case .unknown, .notInstalled:
            "waveform"
        }
    }

    private func updateSelectedChoice(_ choice: TranscriptionModelChoice) {
        guard choice != appModel.transcriptionModels.selectedChoice else {
            return
        }

        guard appModel.setTranscriptionModelChoice(choice, modelContext: modelContext) else {
            selectedChoice = appModel.transcriptionModels.selectedChoice
            return
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

    private func confirmInstall() {
        isConfirmingInstall = true
    }

    private func confirmRepair() {
        isConfirmingRepair = true
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func installModel() {
        appModel.installTranscriptionModel()
    }

    private func repairModel() {
        appModel.repairTranscriptionModel()
    }

    private func deleteModel() {
        appModel.deleteTranscriptionModel()
    }

    private func cancelInstall() {
        appModel.cancelTranscriptionModelInstall()
    }

    private func checkModel() {
        appModel.checkTranscriptionModel()
    }

    @concurrent
    private static func loadModelState(
        modelIdentifier: String,
        version: String
    ) async -> TranscriptionModelState {
        let installStore = OpenCastWhisperModelInstallStore()
        do {
            let summary = try installStore.installedSummary(
                modelIdentifier: modelIdentifier,
                version: version
            )
            return .installed(summary)
        } catch let error as OpenCastTranscriptionError {
            guard case .modelNotInstalled = error else {
                return .failed(error.localizedDescription)
            }
            return .notInstalled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private var installButtonTitle: String {
        "Install \(selectedChoice.title) Model"
    }

    private var deleteButtonTitle: String {
        "Delete \(selectedChoice.title) Model"
    }

    private var installConfirmationTitle: String {
        "Install \(selectedChoice.title.lowercased()) speech model?"
    }

    private var deleteConfirmationTitle: String {
        "Delete \(selectedChoice.title.lowercased()) speech model?"
    }

    private var installConfirmationMessage: String {
        switch selectedChoice {
        case .fastTinyEnglish:
            "The tiny English model is about 50 MB and keeps transcription fastest."
        case .accurateLargeV3:
            "The large-v3 model is about 600 MB and improves transcript accuracy."
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
