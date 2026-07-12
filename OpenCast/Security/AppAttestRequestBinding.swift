import CryptoKit
import Foundation

enum AppAttestRequestBinding {
    nonisolated static func clientDataHash(method: String, path: String, payload: String) -> Data {
        let payloadHash = sha256Hex(Data(payload.utf8))
        let binding = "\(method)\n\(path)\n\(payloadHash)"
        return Data(SHA256.hash(data: Data(binding.utf8)))
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        hexString(Data(SHA256.hash(data: data)))
    }

    nonisolated static func hexString(_ data: Data) -> String {
        data
            .map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0\(hex)" : hex
            }
            .joined()
    }
}
