import OpenCastTranscription

protocol TranscriptionModelInstalling: Sendable {
    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary
    func fetchManifest() async throws -> RemoteWhisperModelManifest
    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary
    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws
}
