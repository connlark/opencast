#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import Testing
@testable import OpenCast

struct AppAttestSignedPayloadJSONCodingTests {
    @Test("Signed App Attest payload JSON is canonical across secure clients")
    func signedAppAttestPayloadJSONIsCanonicalAcrossSecureClients() throws {
        let payload = DatedPayload(
            name: "payload",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let sharedPayload = try AppAttestSignedPayloadJSONCoding.payloadString(payload)
        let securePayload = try AppAttestSecureAPIClient.encodedPayloadString(payload)
        let adAnalysisPayload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(payload)
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/transcript",
            payload: sharedPayload
        )
        let payloadHash = AppAttestRequestBinding.sha256Hex(Data(sharedPayload.utf8))
        let expectedBinding = "POST\n/v1/ad-analysis/transcript\n\(payloadHash)"

        #expect(sharedPayload == #"{"name":"payload","updated_at":"2026-05-28T20:26:40Z"}"#)
        #expect(securePayload == sharedPayload)
        #expect(adAnalysisPayload == sharedPayload)
        #expect(
            AppAttestRequestBinding.hexString(clientDataHash)
                == AppAttestRequestBinding.sha256Hex(Data(expectedBinding.utf8))
        )
    }

    private struct DatedPayload: Encodable {
        let name: String
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case name
            case updatedAt = "updated_at"
        }
    }
}
#endif
