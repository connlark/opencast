import CryptoKit
import OpenCastAnalysis
import Foundation

/// A listener's provider API key, held only for the calls that need it.
/// No textual or reflected form shows it, and the transports send it to
/// their provider's pinned host only.
public struct AnalysisProviderKey: Sendable {
    let value: String

    /// The key with surrounding whitespace removed; `nil` when nothing is left.
    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    /// A line for an app sink with this key, and any credential, redacted
    /// and verified (`[REDACTED LINE]` when anything remains).
    public func safeLine(_ text: String) -> String {
        RedactingLogger.safeLine(text, secrets: [value])
    }

    /// A recorder artifact with this key redacted by structure and verified
    /// for every fragment, or a placeholder.
    public func safeRecording(_ text: String) -> AnalysisSafeRecording {
        RedactingLogger.safeRecording(text, secrets: [value])
    }

    public func safeRecording(_ value: JSONValue) -> AnalysisSafeRecording {
        RedactingLogger.safeRecording(value, secrets: [self.value])
    }

    /// A recorder artifact built from structured fields: verified whole as
    /// it stands, never redacted, or a placeholder.
    public func verifiedRecording(_ value: JSONValue) -> AnalysisSafeRecording {
        RedactingLogger.verifiedRecording(value, verifier: verifier)
    }

    /// The verifier with this key registered, for a recorder's own checks.
    public var verifier: SecretVerifier {
        SecretVerifier(secrets: [value])
    }

    /// Raw access to the key's UTF-8 bytes, for the one caller that persists
    /// the key (the app's Keychain store). This is not a confinement boundary:
    /// whatever `body` does with the bytes holds the secret, so nothing else
    /// should call it; the transports send the key themselves.
    public func withData<Result, Failure: Error>(
        _ body: (Data) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(Data(value.utf8))
    }

    /// A one-way digest that tells keys apart without holding one.
    public var digest: Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }
}

extension AnalysisProviderKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AnalysisProviderKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
