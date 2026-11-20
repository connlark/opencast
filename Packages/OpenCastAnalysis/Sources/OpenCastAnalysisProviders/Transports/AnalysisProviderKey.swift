import CryptoKit
import OpenCastAnalysis
import Foundation

/// No textual or reflected form shows the key, and it goes only to its provider's pinned host.
public struct AnalysisProviderKey: Sendable {
    let value: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    public func safeLine(_ text: String) -> String {
        RedactingLogger.safeLine(text, secrets: [value])
    }

    public func safeRecording(_ text: String) -> AnalysisSafeRecording {
        RedactingLogger.safeRecording(text, secrets: [value])
    }

    public func safeRecording(_ value: JSONValue) -> AnalysisSafeRecording {
        RedactingLogger.safeRecording(value, secrets: [self.value])
    }

    public func verifiedRecording(_ value: JSONValue) -> AnalysisSafeRecording {
        RedactingLogger.verifiedRecording(value, verifier: verifier)
    }

    public var verifier: SecretVerifier {
        SecretVerifier(secrets: [value])
    }

    /// Only for persisting the key in the Keychain. Not a confinement boundary: whatever `body`
    /// does with the bytes holds the secret.
    public func withData<Result, Failure: Error>(
        _ body: (Data) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(Data(value.utf8))
    }

    public var digest: Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }
}

extension AnalysisProviderKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AnalysisProviderKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
