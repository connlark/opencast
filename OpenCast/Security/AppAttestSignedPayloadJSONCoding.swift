import Foundation

nonisolated enum AppAttestSignedPayloadJSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func payloadString(_ payload: some Encodable) throws -> String {
        let data = try encoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }
}
