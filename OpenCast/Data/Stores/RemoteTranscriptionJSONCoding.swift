import Foundation

enum RemoteTranscriptionJSONCoding {
    nonisolated static func encoder() -> JSONEncoder {
        JSONEncoder()
    }

    nonisolated static func canonicalPayloadString(_ payload: some Encodable) throws -> String {
        try AppAttestSignedPayloadJSONCoding.payloadString(payload)
    }

    nonisolated static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
