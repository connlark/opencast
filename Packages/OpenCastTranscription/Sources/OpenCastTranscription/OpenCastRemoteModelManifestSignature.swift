import Foundation

struct OpenCastRemoteModelManifestSignature: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var algorithm: String
    var keyID: String
    var signature: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case algorithm
        case keyID = "key_id"
        case signature
    }
}
