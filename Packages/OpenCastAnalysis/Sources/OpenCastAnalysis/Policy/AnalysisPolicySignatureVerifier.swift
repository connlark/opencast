import CryptoKit
import Foundation

/// Verifies the policy bundle's detached Ed25519 signature against a pinned
/// key. Same envelope and production key as the transcription model
/// manifest's verifier, copied here so this package does not depend on the
/// transcription package.
public struct AnalysisPolicySignatureVerifier: Sendable, Equatable {
    public static let pinned = AnalysisPolicySignatureVerifier(
        publicKeyHex: "795f50cc77f7e9723687492643cb3a99a1c5b1c4d145ab75ce2576d4d955d028",
        keyID: "opencast-remote-models-2026-07"
    )

    public var publicKeyHex: String
    public var keyID: String

    public init(publicKeyHex: String, keyID: String) {
        self.publicKeyHex = publicKeyHex
        self.keyID = keyID
    }

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let algorithm: String
        let keyID: String
        let bundleVersion: Int?
        let sha256: String?
        let signature: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case algorithm
            case keyID = "key_id"
            case bundleVersion = "bundle_version"
            case sha256
            case signature
        }
    }

    /// The bundle a policy signature names: its version and the SHA-256 of its
    /// exact bytes. The loader fetches that version's immutable copy, so a
    /// signature is only ever checked against the bytes it was made for.
    public struct Binding: Sendable, Equatable {
        public let bundleVersion: Int
        public let sha256: String
    }

    /// Reads the binding without verifying anything; the validator checks it
    /// against the bytes and the signature.
    public static func binding(in signatureData: Data) throws(AnalysisPolicyRejection) -> Binding {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: signatureData) else {
            throw .signatureInvalid("unreadable signature envelope")
        }
        guard let version = envelope.bundleVersion, version >= 1,
              let digest = envelope.sha256, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else {
            throw .signatureInvalid("signature does not name its bundle")
        }
        return Binding(bundleVersion: version, sha256: digest)
    }

    public func verify(bundleData: Data, signatureData: Data) throws(AnalysisPolicyRejection) {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: signatureData)
        } catch {
            throw .signatureInvalid("unreadable signature envelope")
        }
        guard envelope.schemaVersion == 1 else {
            throw .signatureInvalid("unsupported signature schema version \(envelope.schemaVersion)")
        }
        guard envelope.algorithm == "ed25519" else {
            throw .signatureInvalid("unsupported signature algorithm")
        }
        guard envelope.keyID == keyID else {
            throw .signatureInvalid("signature key ID does not match the pinned key")
        }
        guard let publicKeyBytes = Self.hexBytes(publicKeyHex),
              let signatureBytes = Self.hexBytes(envelope.signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        else {
            throw .signatureInvalid("malformed key or signature")
        }
        guard publicKey.isValidSignature(signatureBytes, for: bundleData) else {
            throw .signatureInvalid("signature did not verify")
        }
    }

    private static func hexBytes(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
