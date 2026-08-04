import Foundation

public struct OpenCastWhisperModelInstallStore: Sendable, Equatable {
    public var rootDirectory: URL
    private static let receiptFileName = ".opencast-install.json"

    public init(rootDirectory: URL = Self.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRootDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appending(path: "OpenCast")
            .appending(path: "TranscriptionModels")
    }

    public func installedLocation(modelIdentifier: String, version: String) throws -> OpenCastWhisperModelLocation {
        let installDirectory = installDirectory(modelIdentifier: modelIdentifier, version: version)
        guard let receipt = try validReceipt(
            in: installDirectory,
            modelIdentifier: modelIdentifier,
            version: version
        ) else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: modelIdentifier,
                version: version
            )
        }

        let modelFolder = installDirectory.appending(path: "model")
        let tokenizerFolder = installDirectory.appending(path: "tokenizer")
        guard FileManager.default.fileExists(atPath: modelFolder.path),
              FileManager.default.fileExists(atPath: tokenizerFolder.path) else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: modelIdentifier,
                version: version
            )
        }
        guard receipt.files.contains(where: { $0.path.hasPrefix("model/") }),
              receipt.files.contains(where: { $0.path.hasPrefix("tokenizer/") }) else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: modelIdentifier,
                version: version
            )
        }

        return OpenCastWhisperModelLocation(
            modelIdentifier: modelIdentifier,
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder
        )
    }

    public func installedSummary(modelIdentifier: String, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        let installDirectory = installDirectory(modelIdentifier: modelIdentifier, version: version)
        guard let receipt = try validReceipt(
            in: installDirectory,
            modelIdentifier: modelIdentifier,
            version: version
        ) else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: modelIdentifier,
                version: version
            )
        }

        _ = try installedLocation(modelIdentifier: modelIdentifier, version: version)
        return OpenCastWhisperModelInstalledSummary(
            modelIdentifier: receipt.modelIdentifier,
            version: receipt.version,
            totalByteCount: receipt.totalByteCount,
            treeSHA256: receipt.treeSHA256
        )
    }

    func installDirectory(modelIdentifier: String, version: String) -> URL {
        rootDirectory
            .appending(path: modelIdentifier)
            .appending(path: version)
    }

    func makeStagingDirectory() throws -> URL {
        try Self.excludeFromBackup(at: rootDirectory)
        let stagingRoot = rootDirectory.appending(path: ".staging")
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try Self.excludeFromBackup(at: stagingRoot)
        let stagingDirectory = stagingRoot.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try Self.excludeFromBackup(at: stagingDirectory)
        return stagingDirectory
    }

    func promote(stagingDirectory: URL, modelIdentifier: String, version: String) throws {
        let finalDirectory = installDirectory(modelIdentifier: modelIdentifier, version: version)
        try Self.excludeFromBackup(at: rootDirectory)
        try FileManager.default.createDirectory(
            at: finalDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.excludeFromBackup(at: finalDirectory.deletingLastPathComponent())

        if FileManager.default.fileExists(atPath: finalDirectory.path) {
            _ = try FileManager.default.replaceItemAt(
                finalDirectory,
                withItemAt: stagingDirectory,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
        }
        try Self.excludeFromBackup(at: finalDirectory)
    }

    func writeReceipt(_ receipt: OpenCastWhisperModelInstallReceipt, to directory: URL) throws {
        let data = try JSONEncoder.openCastInstallReceiptEncoder.encode(receipt)
        try data.write(to: receiptURL(in: directory), options: [.atomic])
    }

    public func deleteInstalledModel(modelIdentifier: String, version: String) throws {
        let installDirectory = installDirectory(modelIdentifier: modelIdentifier, version: version)
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try FileManager.default.removeItem(at: installDirectory)
        }
    }

    private func validReceipt(
        in installDirectory: URL,
        modelIdentifier: String,
        version: String
    ) throws -> OpenCastWhisperModelInstallReceipt? {
        let receiptURL = receiptURL(in: installDirectory)
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(OpenCastWhisperModelInstallReceipt.self, from: data),
              receipt.schemaVersion == 1,
              receipt.modelIdentifier == modelIdentifier,
              receipt.version == version,
              receipt.treeSHA256.count == 64,
              receipt.totalByteCount >= 0 else {
            return nil
        }

        var totalByteCount: Int64 = 0
        var paths = Set<String>()
        for file in receipt.files {
            guard file.byteCount >= 0,
                  file.sha256.count == 64,
                  paths.insert(file.path).inserted else {
                return nil
            }
            guard let fileURL = try? OpenCastRemoteModelFilePath.destinationURL(
                for: file.path,
                rootDirectory: installDirectory
            ) else {
                return nil
            }
            guard let actualByteCount = try? OpenCastFileByteCount.byteCount(at: fileURL),
                  actualByteCount == file.byteCount else {
                return nil
            }
            let (newTotal, overflow) = totalByteCount.addingReportingOverflow(file.byteCount)
            guard !overflow else {
                return nil
            }
            totalByteCount = newTotal
        }

        guard totalByteCount == receipt.totalByteCount else {
            return nil
        }
        return receipt
    }

    private func receiptURL(in directory: URL) -> URL {
        directory.appending(path: Self.receiptFileName)
    }

    static func excludeFromBackup(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var excludedURL = url
        try excludedURL.setResourceValues(resourceValues)
    }
}

private extension JSONEncoder {
    static var openCastInstallReceiptEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
