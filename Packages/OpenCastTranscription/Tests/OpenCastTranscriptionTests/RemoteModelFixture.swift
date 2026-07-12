import Foundation
@testable import OpenCastTranscription

struct RemoteModelFixture {
    var configuration: OpenCastRemoteModelGatewayConfiguration
    var manifest: RemoteWhisperModelManifest
    var model: RemoteWhisperModel
    var downloads: [URL: Data]

    init(
        modelBytes: Data = Data("model config".utf8),
        tokenizerBytes: Data = Data("tokenizer config".utf8),
        configureModel: (inout RemoteWhisperModel) -> Void = { _ in }
    ) throws {
        configuration = OpenCastRemoteModelGatewayConfiguration(
            baseURL: URL(string: "https://models.example.test")!
        )
        let modelID = OpenCastWhisperModel.largeV3.rawValue
        let version = OpenCastWhisperModel.largeV3.defaultRemoteVersion
        let files = [
            RemoteWhisperModelFile(
                path: "model/config.json",
                urlPath: "/v1/models/assets/\(modelID)/\(version)/model/config.json",
                byteCount: Int64(modelBytes.count),
                sha256: OpenCastSHA256.hash(modelBytes),
                contentType: "application/json; charset=utf-8"
            ),
            RemoteWhisperModelFile(
                path: "tokenizer/tokenizer.json",
                urlPath: "/v1/models/assets/\(modelID)/\(version)/tokenizer/tokenizer.json",
                byteCount: Int64(tokenizerBytes.count),
                sha256: OpenCastSHA256.hash(tokenizerBytes),
                contentType: "application/json; charset=utf-8"
            )
        ]
        model = RemoteWhisperModel(
            modelID: modelID,
            version: version,
            modelFolder: "model",
            tokenizerFolder: "tokenizer",
            totalByteCount: Int64(modelBytes.count + tokenizerBytes.count),
            treeSHA256: OpenCastRemoteModelTreeHash.hash(files: files),
            files: files
        )
        configureModel(&model)
        manifest = RemoteWhisperModelManifest(
            schemaVersion: 1,
            generatedAt: "2026-06-28T00:00:00Z",
            models: [model]
        )
        downloads = [
            try configuration.assetURL(forPath: files[0].urlPath): modelBytes,
            try configuration.assetURL(forPath: files[1].urlPath): tokenizerBytes
        ]
    }
}
