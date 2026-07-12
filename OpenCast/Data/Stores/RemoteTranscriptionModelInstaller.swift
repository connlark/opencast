import OpenCastTranscription

struct RemoteTranscriptionModelInstaller: TranscriptionModelInstalling {
    var installer: OpenCastWhisperModelInstaller
    var installStore: OpenCastWhisperModelInstallStore

    init(
        installer: OpenCastWhisperModelInstaller = OpenCastWhisperModelInstaller(),
        installStore: OpenCastWhisperModelInstallStore = OpenCastWhisperModelInstallStore()
    ) {
        self.installer = installer
        self.installStore = installStore
    }

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        try installStore.installedSummary(modelIdentifier: model.rawValue, version: version)
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        try await installer.fetchManifest()
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        _ = try await installer.install(
            manifest: manifest,
            model: model,
            version: version,
            progress: progress
        )
        return try installedSummary(model: model, version: version)
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
        try installer.deleteInstalledModel(model: model, version: version)
    }
}
