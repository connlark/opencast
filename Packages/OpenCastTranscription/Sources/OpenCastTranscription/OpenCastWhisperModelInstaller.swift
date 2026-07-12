import Foundation

public struct OpenCastWhisperModelInstaller: Sendable {
    public var configuration: OpenCastRemoteModelGatewayConfiguration
    public var installStore: OpenCastWhisperModelInstallStore
    public var limits: OpenCastWhisperModelInstallLimits
    private var transport: any OpenCastRemoteModelTransport
    private var manifestVerifier: any OpenCastRemoteModelManifestVerifying

    public init(
        configuration: OpenCastRemoteModelGatewayConfiguration = OpenCastRemoteModelGatewayConfiguration(),
        installStore: OpenCastWhisperModelInstallStore = OpenCastWhisperModelInstallStore(),
        limits: OpenCastWhisperModelInstallLimits = .largeV3
    ) {
        self.init(
            configuration: configuration,
            installStore: installStore,
            limits: limits,
            transport: URLSessionRemoteModelTransport(),
            manifestVerifier: OpenCastRemoteModelManifestVerifier.pinned
        )
    }

    init(
        configuration: OpenCastRemoteModelGatewayConfiguration = OpenCastRemoteModelGatewayConfiguration(),
        installStore: OpenCastWhisperModelInstallStore = OpenCastWhisperModelInstallStore(),
        limits: OpenCastWhisperModelInstallLimits = .largeV3,
        transport: any OpenCastRemoteModelTransport,
        manifestVerifier: any OpenCastRemoteModelManifestVerifying
    ) {
        self.configuration = configuration
        self.installStore = installStore
        self.limits = limits
        self.transport = transport
        self.manifestVerifier = manifestVerifier
    }

    public func fetchManifest() async throws -> RemoteWhisperModelManifest {
        let manifestURL = try configuration.manifestURL()
        let signatureURL = try configuration.manifestSignatureURL()

        async let manifestResult = transport.data(from: manifestURL)
        async let signatureResult = transport.data(from: signatureURL)
        let manifestResponse = try await manifestResult
        let signatureResponse = try await signatureResult

        guard manifestResponse.response.isSuccessfulHTTPResponse else {
            throw OpenCastTranscriptionError.remoteManifestUnavailable(manifestURL)
        }
        guard signatureResponse.response.isSuccessfulHTTPResponse else {
            throw OpenCastTranscriptionError.remoteManifestSignatureUnavailable(signatureURL)
        }
        try manifestVerifier.verify(
            manifestData: manifestResponse.data,
            signatureData: signatureResponse.data
        )

        let manifest = try JSONDecoder().decode(RemoteWhisperModelManifest.self, from: manifestResponse.data)
        try validate(manifest: manifest)
        return manifest
    }

    public func install(
        model: OpenCastWhisperModel = .largeV3,
        version: String? = nil,
        progress: OpenCastWhisperModelInstallProgressHandler? = nil
    ) async throws -> OpenCastWhisperModelLocation {
        let manifest = try await fetchManifest()
        return try await install(
            manifest: manifest,
            model: model,
            version: version,
            progress: progress
        )
    }

    public func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel = .largeV3,
        version: String? = nil,
        progress: OpenCastWhisperModelInstallProgressHandler? = nil
    ) async throws -> OpenCastWhisperModelLocation {
        try validate(manifest: manifest)
        let version = try resolvedVersion(for: model, version: version)
        guard let remoteModel = manifest.model(modelIdentifier: model.rawValue, version: version) else {
            throw OpenCastTranscriptionError.remoteManifestMissingModel(
                modelIdentifier: model.rawValue,
                version: version
            )
        }
        try validate(remoteModel: remoteModel)

        let stagingDirectory = try installStore.makeStagingDirectory()
        do {
            try await downloadFiles(
                remoteModel: remoteModel,
                stagingDirectory: stagingDirectory,
                progress: progress
            )
            try verifyTreeHash(for: remoteModel)
            try installStore.writeReceipt(
                OpenCastWhisperModelInstallReceipt(model: remoteModel),
                to: stagingDirectory
            )
            try installStore.promote(
                stagingDirectory: stagingDirectory,
                modelIdentifier: remoteModel.modelID,
                version: remoteModel.version
            )
            return try installStore.installedLocation(
                modelIdentifier: remoteModel.modelID,
                version: remoteModel.version
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    public func installedLocation(
        model: OpenCastWhisperModel = .largeV3,
        version: String? = nil
    ) throws -> OpenCastWhisperModelLocation {
        let version = try resolvedVersion(for: model, version: version)
        return try installStore.installedLocation(
            modelIdentifier: model.rawValue,
            version: version
        )
    }

    public func deleteInstalledModel(
        model: OpenCastWhisperModel = .largeV3,
        version: String? = nil
    ) throws {
        let version = try resolvedVersion(for: model, version: version)
        try installStore.deleteInstalledModel(
            modelIdentifier: model.rawValue,
            version: version
        )
    }

    private func downloadFiles(
        remoteModel: RemoteWhisperModel,
        stagingDirectory: URL,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws {
        var completedFileCount = 0
        var completedByteCount: Int64 = 0
        let totalFileCount = remoteModel.files.count

        progress?(
            OpenCastWhisperModelInstallProgress(
                modelIdentifier: remoteModel.modelID,
                version: remoteModel.version,
                completedFileCount: completedFileCount,
                totalFileCount: totalFileCount,
                completedByteCount: completedByteCount,
                totalByteCount: remoteModel.totalByteCount,
                currentFilePath: nil
            )
        )

        for file in remoteModel.files {
            try Task.checkCancellation()
            let destination = try OpenCastRemoteModelFilePath.destinationURL(
                for: file.path,
                rootDirectory: stagingDirectory
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sourceURL = try configuration.assetURL(forPath: file.urlPath)
            let response = try await transport.download(
                from: sourceURL,
                to: destination,
                expectedByteCount: file.byteCount,
                maximumByteCount: limits.maximumFileByteCount
            )
            guard response.isSuccessfulHTTPResponse else {
                try? FileManager.default.removeItem(at: destination)
                throw OpenCastTranscriptionError.remoteModelDownloadFailed(sourceURL)
            }
            try Task.checkCancellation()
            let actualByteCount = try await fileByteCount(at: destination)
            guard actualByteCount == file.byteCount else {
                try? FileManager.default.removeItem(at: destination)
                throw OpenCastTranscriptionError.invalidRemoteManifest(
                    "downloaded byte count for \(file.path) was \(actualByteCount), expected \(file.byteCount)"
                )
            }
            let actualSHA256 = try await OpenCastSHA256.hashFileOffCaller(at: destination)
            guard actualSHA256 == file.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: destination)
                throw OpenCastTranscriptionError.checksumMismatch(
                    path: file.path,
                    expected: file.sha256,
                    actual: actualSHA256
                )
            }

            completedFileCount += 1
            completedByteCount += file.byteCount
            progress?(
                OpenCastWhisperModelInstallProgress(
                    modelIdentifier: remoteModel.modelID,
                    version: remoteModel.version,
                    completedFileCount: completedFileCount,
                    totalFileCount: totalFileCount,
                    completedByteCount: completedByteCount,
                    totalByteCount: remoteModel.totalByteCount,
                    currentFilePath: file.path
                )
            )
        }
    }

    private func resolvedVersion(for model: OpenCastWhisperModel, version: String?) throws -> String {
        if let version {
            return version
        }
        return model.defaultRemoteVersion
    }

    private func validate(manifest: RemoteWhisperModelManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "unsupported schema version \(manifest.schemaVersion)"
            )
        }
        guard !manifest.models.isEmpty else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("manifest must include at least one model")
        }
    }

    private func validate(remoteModel: RemoteWhisperModel) throws {
        guard remoteModel.modelFolder == "model",
              remoteModel.tokenizerFolder == "tokenizer" else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "model and tokenizer folders must be model/tokenizer"
            )
        }
        guard !remoteModel.files.isEmpty else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("model must include files")
        }
        var totalByteCount: Int64 = 0
        var paths = Set<String>()
        for file in remoteModel.files {
            _ = try OpenCastRemoteModelFilePath.components(for: file.path)
            guard paths.insert(file.path).inserted else {
                throw OpenCastTranscriptionError.invalidRemoteManifest("duplicate file path: \(file.path)")
            }
            guard !file.urlPath.isEmpty,
                  file.sha256.count == 64,
                  file.byteCount >= 0,
                  file.byteCount <= limits.maximumFileByteCount else {
                throw OpenCastTranscriptionError.invalidRemoteManifest("bad file metadata: \(file.path)")
            }
            let (newTotal, overflow) = totalByteCount.addingReportingOverflow(file.byteCount)
            guard !overflow else {
                throw OpenCastTranscriptionError.invalidRemoteManifest("total byte count overflow")
            }
            totalByteCount = newTotal
        }
        guard totalByteCount == remoteModel.totalByteCount else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("total byte count mismatch")
        }
        guard remoteModel.totalByteCount <= limits.maximumTotalByteCount else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("total byte count exceeds configured limits")
        }
    }

    private func verifyTreeHash(for remoteModel: RemoteWhisperModel) throws {
        let actualTreeHash = OpenCastRemoteModelTreeHash.hash(files: remoteModel.files)
        guard actualTreeHash == remoteModel.treeSHA256.lowercased() else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "tree hash for \(remoteModel.modelID) \(remoteModel.version) was \(actualTreeHash), expected \(remoteModel.treeSHA256)"
            )
        }
    }

    @concurrent
    private static func fileByteCount(at url: URL) async throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw OpenCastTranscriptionError.invalidRemoteManifest("bad file metadata: \(url.path)")
        }
        return Int64(fileSize)
    }

    private func fileByteCount(at url: URL) async throws -> Int64 {
        try await Self.fileByteCount(at: url)
    }
}
