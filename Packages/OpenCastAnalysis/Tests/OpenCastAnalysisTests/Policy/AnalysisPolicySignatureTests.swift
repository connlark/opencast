import Foundation
@testable import OpenCastAnalysis
import Testing

@Suite("Analysis policy signature")
struct AnalysisPolicySignatureTests {
    @Test("Pinned verifier accepts the production-signed bundle and model manifest")
    func pinnedVerifierAcceptsProductionSignedDocuments() throws {
        let version = BakedAnalysisPolicy.bundleVersion
        try AnalysisPolicySignatureVerifier.pinned.verify(
            bundleData: PolicyTestSupport.gatewayFile("manifests/analysis-policy/v\(version).json"),
            signatureData: PolicyTestSupport.gatewayFile("manifests/analysis-policy/v\(version).json.sig")
        )
        // The transcription package's pinned verifier accepts these same
        // bytes (its own checked-in-manifest test), so the two verifiers
        // agree on production-signed input.
        try AnalysisPolicySignatureVerifier.pinned.verify(
            bundleData: PolicyTestSupport.gatewayFile("manifests/current.json"),
            signatureData: PolicyTestSupport.gatewayFile("manifests/current.json.sig")
        )
    }

    @Test("Both verifiers pin the same key")
    func verifiersPinTheSameKey() throws {
        let source = try String(
            contentsOf: PolicyTestSupport.repoRoot.appending(
                path: "Packages/OpenCastTranscription/Sources/OpenCastTranscription/OpenCastRemoteModelManifestVerifier.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains(#"publicKeyHex: "\#(AnalysisPolicySignatureVerifier.pinned.publicKeyHex)""#))
        #expect(source.contains(#"keyID: "\#(AnalysisPolicySignatureVerifier.pinned.keyID)""#))
    }

    @Test("Round trip: generator-signed test fixture verifies with the test key only")
    func testSeedRoundTrip() throws {
        let good = PolicyTestSupport.data(AnalysisPolicyTestFixtures.good)
        try PolicyTestSupport.testVerifier.verify(bundleData: good.bundle, signatureData: good.signature)
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("signature key ID does not match the pinned key")) {
            try AnalysisPolicySignatureVerifier.pinned.verify(bundleData: good.bundle, signatureData: good.signature)
        }
        let impostor = AnalysisPolicySignatureVerifier(
            publicKeyHex: AnalysisPolicySignatureVerifier.pinned.publicKeyHex,
            keyID: AnalysisPolicyTestFixtures.keyID
        )
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("signature did not verify")) {
            try impostor.verify(bundleData: good.bundle, signatureData: good.signature)
        }
    }

    @Test("A changed byte, a bad signature or a malformed envelope fails")
    func tamperingFails() throws {
        let good = PolicyTestSupport.data(AnalysisPolicyTestFixtures.good)
        var tampered = good.bundle
        tampered[tampered.count / 2] ^= 0x01
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("signature did not verify")) {
            try PolicyTestSupport.testVerifier.verify(bundleData: tampered, signatureData: good.signature)
        }
        let bad = PolicyTestSupport.data(AnalysisPolicyTestFixtures.badSignature)
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("signature did not verify")) {
            try PolicyTestSupport.testVerifier.verify(bundleData: bad.bundle, signatureData: bad.signature)
        }
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("unreadable signature envelope")) {
            try PolicyTestSupport.testVerifier.verify(bundleData: good.bundle, signatureData: Data("{}".utf8))
        }
        let otherAlgorithm = String(decoding: good.signature, as: UTF8.self).replacing("ed25519", with: "rsa")
        #expect(throws: AnalysisPolicyRejection.signatureInvalid("unsupported signature algorithm")) {
            try PolicyTestSupport.testVerifier.verify(bundleData: good.bundle, signatureData: Data(otherAlgorithm.utf8))
        }
    }
}
