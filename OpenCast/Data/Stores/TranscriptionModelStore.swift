import Foundation
import Observation
import OpenCastTranscription
import SwiftData

@Observable
final class TranscriptionModelStore {
    static let modelChoicePreferenceKey = "transcription.model.choice"

    @ObservationIgnored private let stateChanges = StoreChangeNotifier()

    private(set) var selectedChoice: TranscriptionModelChoice = .defaultChoice
    private(set) var state: TranscriptionModelState = .unknown {
        didSet {
            guard oldValue != state else {
                return
            }
            stateChanges.notify()
        }
    }

    @ObservationIgnored private let installer: any TranscriptionModelInstalling
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var activeInstallOperationID: UUID?

    init(
        installer: any TranscriptionModelInstalling = RemoteTranscriptionModelInstaller()
    ) {
        self.installer = installer
    }

    var installedSummary: OpenCastWhisperModelInstalledSummary? {
        switch state {
        case .installed(let summary), .repairAvailable(let summary):
            return summary
        default:
            return nil
        }
    }

    func installedSummary(for choice: TranscriptionModelChoice) throws -> OpenCastWhisperModelInstalledSummary {
        try installer.installedSummary(model: choice.model, version: choice.defaultVersion)
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing, .deleting:
            true
        case .unknown, .notInstalled, .installed, .repairAvailable, .failed:
            false
        }
    }

    // Test seam — no production callers (dead-code audit Low 40).
    var canStartTranscription: Bool {
        if case .installed = state {
            true
        } else {
            false
        }
    }

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    // Test seam — no production callers (dead-code audit Low 40).
    func loadLocalStatus() {
        state = localStatus()
    }

    func load(modelContext: ModelContext) {
        do {
            selectedChoice = try storedChoice(modelContext: modelContext)
            state = localStatus()
        } catch {
            selectedChoice = .defaultChoice
            state = .failed("Unable to load transcript model choice: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func setSelectedChoice(
        _ choice: TranscriptionModelChoice,
        modelContext: ModelContext
    ) -> Bool {
        guard operationTask == nil else {
            state = .failed("Wait for the current speech model operation to finish.")
            return false
        }

        let previousChoice = selectedChoice
        selectedChoice = choice
        state = localStatus()

        do {
            try LocalPreferenceRecord.upsert(
                key: Self.modelChoicePreferenceKey,
                value: choice.rawValue,
                modelContext: modelContext
            )
            try modelContext.save()
            return true
        } catch {
            selectedChoice = previousChoice
            state = .failed("Unable to update transcript model: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func installPinnedModel() -> Bool {
        startInstall()
    }

    @discardableResult
    func repairPinnedModel() -> Bool {
        startInstall()
    }

    func cancelInstall() {
        operationTask?.cancel()
    }

    func checkRemoteManifest() {
        guard operationTask == nil else {
            return
        }

        operationTask = Task {
            state = .checking
            do {
                let manifest = try await installer.fetchManifest()
                try Task.checkCancellation()
                state = try checkedState(manifest: manifest)
            } catch is CancellationError {
                state = localStatus()
            } catch {
                state = .failed(error.localizedDescription)
            }
            operationTask = nil
        }
    }

    func selectedModelRemoteByteCount() async throws -> Int64 {
        let manifest = try await installer.fetchManifest()
        let remoteModel = try remoteModel(
            in: manifest,
            model: selectedModel,
            version: selectedVersion
        )
        return remoteModel.totalByteCount
    }

    func deleteInstalledModel() {
        guard operationTask == nil else {
            return
        }

        operationTask = Task {
            try? performDeleteInstalledModel()
            operationTask = nil
        }
    }

    func deleteInstalledModelImmediately() throws {
        operationTask?.cancel()
        operationTask = nil
        activeInstallOperationID = nil
        try performDeleteInstalledModel()
        selectedChoice = .defaultChoice
        state = localStatus()
    }

    /// Deliberately synchronous and main-actor: the data-nuke ordering
    /// guarantee beside `resetRuntimeStateAfterDataNuke` depends on the
    /// removal completing before the nuke proceeds. The catch keeps any
    /// throw from stranding `.deleting` — the Settings section renders that
    /// state as a bare spinner with no way out.
    private func performDeleteInstalledModel() throws {
        state = .deleting
        do {
            try installer.deleteInstalledModel(model: selectedModel, version: selectedVersion)
            state = localStatus()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func resetAfterDataNuke() {
        operationTask?.cancel()
        operationTask = nil
        activeInstallOperationID = nil
        selectedChoice = .defaultChoice
        state = localStatus()
    }

    func fail(_ message: String) {
        state = .failed(message)
    }

    private func startInstall() -> Bool {
        guard operationTask == nil else {
            return false
        }

        let operationID = UUID()
        let model = selectedModel
        let version = selectedVersion
        activeInstallOperationID = operationID
        operationTask = Task {
            state = .checking
            do {
                let manifest = try await installer.fetchManifest()
                let remoteModel = try remoteModel(in: manifest, model: model, version: version)
                state = .installing(OpenCastWhisperModelInstallProgress(
                    modelIdentifier: remoteModel.modelID,
                    version: remoteModel.version,
                    completedFileCount: 0,
                    totalFileCount: remoteModel.files.count,
                    completedByteCount: 0,
                    totalByteCount: remoteModel.totalByteCount,
                    currentFilePath: nil
                ))
                let summary = try await installer.install(
                    manifest: manifest,
                    model: model,
                    version: version,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.applyInstallProgress(progress, operationID: operationID)
                        }
                    }
                )
                try Task.checkCancellation()
                activeInstallOperationID = nil
                state = .installed(summary)
            } catch is CancellationError {
                activeInstallOperationID = nil
                state = localStatus()
            } catch {
                activeInstallOperationID = nil
                state = .failed(error.localizedDescription)
            }
            operationTask = nil
        }
        return true
    }

    private func applyInstallProgress(
        _ progress: OpenCastWhisperModelInstallProgress,
        operationID: UUID
    ) {
        guard activeInstallOperationID == operationID,
              case .installing(let currentProgress) = state,
              currentProgress.modelIdentifier == progress.modelIdentifier,
              currentProgress.version == progress.version
        else {
            return
        }

        state = .installing(progress)
    }

    private func checkedState(manifest: RemoteWhisperModelManifest) throws -> TranscriptionModelState {
        let remoteModel = try remoteModel(in: manifest, model: selectedModel, version: selectedVersion)
        do {
            let summary = try installer.installedSummary(model: selectedModel, version: selectedVersion)
            if summary.treeSHA256.lowercased() == remoteModel.treeSHA256.lowercased() {
                return .installed(summary)
            }
            return .repairAvailable(summary)
        } catch let error as OpenCastTranscriptionError {
            guard case .modelNotInstalled = error else {
                throw error
            }
            return .notInstalled
        }
    }

    private func localStatus() -> TranscriptionModelState {
        do {
            return .installed(try installer.installedSummary(model: selectedModel, version: selectedVersion))
        } catch let error as OpenCastTranscriptionError {
            guard case .modelNotInstalled = error else {
                return .failed(error.localizedDescription)
            }
            return .notInstalled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func storedChoice(modelContext: ModelContext) throws -> TranscriptionModelChoice {
        guard let rawValue = try LocalPreferenceRecord.preference(
            forKey: Self.modelChoicePreferenceKey,
            modelContext: modelContext
        )?.value else {
            return .defaultChoice
        }

        return TranscriptionModelChoice(rawValue: rawValue) ?? .defaultChoice
    }

    private var selectedModel: OpenCastWhisperModel {
        selectedChoice.model
    }

    private var selectedVersion: String {
        selectedChoice.defaultVersion
    }

    private func remoteModel(
        in manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String
    ) throws -> RemoteWhisperModel {
        guard let remoteModel = manifest.model(
            modelIdentifier: model.rawValue,
            version: version
        ) else {
            throw OpenCastTranscriptionError.remoteManifestMissingModel(
                modelIdentifier: model.rawValue,
                version: version
            )
        }
        return remoteModel
    }
}
