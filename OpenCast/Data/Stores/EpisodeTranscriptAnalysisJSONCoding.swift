import Foundation

enum EpisodeTranscriptAnalysisJSONCoding {
    nonisolated static func encoder(outputFormatting: JSONEncoder.OutputFormatting = []) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = outputFormatting
        return encoder
    }

    nonisolated static func canonicalPayloadString(_ payload: some Encodable) throws -> String {
        try AppAttestSignedPayloadJSONCoding.payloadString(payload)
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
