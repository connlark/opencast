import Foundation
import OpenCastTranscription

/// UI-test installer. `install` must durably flip the installed flag: after
/// the store reports `.installed`, the plan resolver independently re-checks
/// `installedSummary(model:version:)`, and a fake that still throws there
/// sends the request coordinator's resolve/ensure loop into a main-actor
/// spin that hangs the app.
final class OpenCastUITestTranscriptionModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Bool

    init(isInstalled: Bool) {
        installed = isInstalled
    }

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        guard lock.withLock({ installed }) else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: model.rawValue,
                version: version
            )
        }
        return summary(for: model)
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(
            schemaVersion: 1,
            generatedAt: "2026-06-29T00:00:00Z",
            models: OpenCastWhisperModel.allCases.map { model in
                remoteModel(summary: summary(for: model))
            }
        )
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        lock.withLock { installed = true }
        return summary(for: model)
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
        lock.withLock { installed = false }
    }

    private func summary(for model: OpenCastWhisperModel) -> OpenCastWhisperModelInstalledSummary {
        switch model {
        case .tinyEnglish:
            OpenCastWhisperModelInstalledSummary(
                modelIdentifier: model.rawValue,
                version: model.defaultRemoteVersion,
                totalByteCount: 78_900_000,
                treeSHA256: String(repeating: "b", count: 64)
            )
        case .largeV3:
            OpenCastWhisperModelInstalledSummary(
                modelIdentifier: model.rawValue,
                version: model.defaultRemoteVersion,
                totalByteCount: 629_482_970,
                treeSHA256: "20a910bd8ea9f94a3e4438780f6e2f0aa3bbcd3fc1f8e99fccb2d64b68935603"
            )
        }
    }

    private func remoteModel(summary: OpenCastWhisperModelInstalledSummary) -> RemoteWhisperModel {
        RemoteWhisperModel(
            modelID: summary.modelIdentifier,
            version: summary.version,
            modelFolder: "model",
            tokenizerFolder: "tokenizer",
            totalByteCount: summary.totalByteCount,
            treeSHA256: summary.treeSHA256,
            files: []
        )
    }
}
