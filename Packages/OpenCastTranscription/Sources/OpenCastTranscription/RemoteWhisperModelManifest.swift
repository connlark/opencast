import Foundation

public struct RemoteWhisperModelManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: String
    public var models: [RemoteWhisperModel]

    public init(
        schemaVersion: Int,
        generatedAt: String,
        models: [RemoteWhisperModel]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.models = models
    }

    public func model(modelIdentifier: String, version: String) -> RemoteWhisperModel? {
        models.first { model in
            model.modelID == modelIdentifier && model.version == version
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case models
    }
}
