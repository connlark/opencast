import Foundation

public struct DownloadedWhisperModelLocator: OpenCastWhisperModelLocating {
    public var model: OpenCastWhisperModel
    public var version: String
    public var installStore: OpenCastWhisperModelInstallStore

    public init(
        model: OpenCastWhisperModel = .largeV3,
        version: String? = nil,
        installStore: OpenCastWhisperModelInstallStore = OpenCastWhisperModelInstallStore()
    ) {
        self.model = model
        self.version = version ?? model.defaultRemoteVersion
        self.installStore = installStore
    }

    public func modelLocation() throws -> OpenCastWhisperModelLocation {
        guard !version.isEmpty else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "\(model.rawValue) version must not be empty"
            )
        }
        return try installStore.installedLocation(
            modelIdentifier: model.rawValue,
            version: version
        )
    }
}
