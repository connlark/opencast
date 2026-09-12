import OpenCastTranscription
import SwiftUI

struct SettingsWhisperModelSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var selectedChoice = TranscriptionModelChoice.defaultChoice
    @State private var isConfirmingInstall = false
    @State private var isConfirmingRepair = false
    @State private var isConfirmingDelete = false
    @State private var loadedModelState = TranscriptionModelState.unknown

    var body: some View {
        Section {
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

            statusRow

            switch modelState {
            case .unknown, .notInstalled, .failed:
                Button(installButtonTitle, systemImage: "arrow.down.circle", action: confirmInstall)
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
            case .checking:
                ProgressView("Checking Model")
            case .installing(let progress):
                SettingsTranscriptionModelInstallProgressView(progress: progress)
                Button("Cancel Install", systemImage: "xmark.circle", role: .cancel, action: cancelInstall)
            case .installed:
                Button("Check Model", systemImage: "arrow.clockwise", action: checkModel)
                deleteButton
            case .repairAvailable:
                Button("Repair Model", systemImage: "wrench.and.screwdriver", action: confirmRepair)
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
                deleteButton
            case .deleting:
                ProgressView("Deleting Model")
            }
        } header: {
            Text("Whisper Model")
        }
        .onChange(of: selectedChoice) { _, newChoice in
            updateSelectedChoice(newChoice)
        }
        .onChange(of: appModel.transcriptionModels.selectedChoice) { _, storeChoice in
            guard selectedChoice != storeChoice else {
                return
            }
            selectedChoice = storeChoice
        }
        .task {
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

    private var statusRow: some View {
        LabeledContent {
            Text(statusText)
        } label: {
            Label("Status", systemImage: statusSystemImage)
        }
    }

    private var deleteButton: some View {
        Button(deleteButtonTitle, systemImage: "trash", role: .destructive, action: confirmDelete)
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
    }

    private var modelState: TranscriptionModelState {
        if case .unknown = appModel.transcriptionModels.state {
            loadedModelState
        } else {
            appModel.transcriptionModels.state
        }
    }

    private var statusText: String {
        switch modelState {
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
        switch modelState {
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
