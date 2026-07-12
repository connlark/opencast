import CryptoKit
import Foundation

struct OpenCastRemoteModelManifestVerifier: OpenCastRemoteModelManifestVerifying {
    static let pinned = OpenCastRemoteModelManifestVerifier(
        publicKeyHex: "795f50cc77f7e9723687492643cb3a99a1c5b1c4d145ab75ce2576d4d955d028",
        keyID: "opencast-remote-models-2026-07"
    )

    var publicKeyHex: String
    var keyID: String

    func verify(manifestData: Data, signatureData: Data) throws {
        let envelope = try JSONDecoder().decode(OpenCastRemoteModelManifestSignature.self, from: signatureData)
        guard envelope.schemaVersion == 1 else {
            throw OpenCastTranscriptionError.invalidRemoteManifestSignature(
                "unsupported signature schema version \(envelope.schemaVersion)"
            )
        }
        guard envelope.algorithm == "ed25519" else {
            throw OpenCastTranscriptionError.invalidRemoteManifestSignature(
                "unsupported signature algorithm \(envelope.algorithm)"
            )
        }
        guard envelope.keyID == keyID else {
            throw OpenCastTranscriptionError.invalidRemoteManifestSignature(
                "signature key ID \(envelope.keyID) does not match pinned key"
            )
        }

        let publicKeyBytes = try Self.hexBytes(publicKeyHex)
        let signatureBytes = try Self.hexBytes(envelope.signature)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        guard publicKey.isValidSignature(signatureBytes, for: manifestData) else {
            throw OpenCastTranscriptionError.invalidRemoteManifestSignature(
                "manifest signature did not verify"
            )
        }
    }

    private static func hexBytes(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else {
            throw OpenCastTranscriptionError.invalidRemoteManifestSignature("invalid hex length")
        }

        var data = Data()
        data.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let nextIndex = trimmed.index(index, offsetBy: 2)
            let byteString = trimmed[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw OpenCastTranscriptionError.invalidRemoteManifestSignature("invalid hex byte")
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
