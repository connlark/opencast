import Foundation
import Testing
@testable import OpenCastTranscription

@Suite("Remote transcription purchase wire types")
struct OpenCastRemoteTranscriptionPurchaseWireTests {
    @Test("Bootstrap response decodes purchase-lane fields and tolerates their absence")
    func bootstrapResponsePurchaseFields() throws {
        let purchaseLane = """
        {
          "schema_version": 1,
          "account_id": "pacct-abc",
          "balance": { "available_seconds": 3600, "reserved_seconds": 0, "debt_seconds": 0 },
          "app_account_token": "3e6f9a2c-4a5f-4a86-9e51-1f0f74d3ab10",
          "catalog": [
            { "product_id": "com.connor.opencast.transcription.hours20.v1", "grant_seconds": 72000 },
            { "product_id": "com.connor.opencast.transcription.hours100.v1", "grant_seconds": 360000 }
          ],
          "catalog_sha256": "c2b007bc37825865aa679166a6fa7d1b0d74c141999f459c12e056f3c7134ec5",
          "purchases_enabled": true
        }
        """
        let response = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionBootstrapResponse.self,
            from: Data(purchaseLane.utf8)
        )
        #expect(response.appAccountToken == "3e6f9a2c-4a5f-4a86-9e51-1f0f74d3ab10")
        #expect(response.catalog?.count == 2)
        #expect(response.catalog?.first?.grantSeconds == 72000)
        #expect(response.catalogSHA256?.hasPrefix("c2b007bc") == true)
        #expect(response.purchasesEnabled == true)

        let devLane = """
        {
          "schema_version": 1,
          "account_id": "acct-dev",
          "balance": { "available_seconds": 36000, "reserved_seconds": 0, "debt_seconds": 0 }
        }
        """
        let devResponse = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionBootstrapResponse.self,
            from: Data(devLane.utf8)
        )
        #expect(devResponse.appAccountToken == nil)
        #expect(devResponse.catalog == nil)
        #expect(devResponse.purchasesEnabled == nil)
    }

    @Test("Redeem request encodes snake_case keys with the current schema version")
    func redeemRequestEncodes() throws {
        let request = OpenCastRemoteTranscriptionRedeemRequest(transactionJWS: "a.b.c")
        let encoded = try JSONDecoder().decode(
            [String: OpenCastRemoteTranscriptionAnyJSON].self,
            from: JSONEncoder().encode(request)
        )
        #expect(encoded["schema_version"] == .number(1))
        #expect(encoded["transaction_jws"] == .string("a.b.c"))
    }

    @Test("Redeem response decodes every outcome and preserves unknowns")
    func redeemResponseOutcomes() throws {
        func decode(_ outcome: String) throws -> OpenCastRemoteTranscriptionRedeemResponse {
            let json = """
            {
              "schema_version": 1,
              "outcome": "\(outcome)",
              "transaction_id": "txn-1",
              "credited_seconds": 72000,
              "balance": { "available_seconds": 75600, "reserved_seconds": 0, "debt_seconds": 0 }
            }
            """
            return try JSONDecoder().decode(
                OpenCastRemoteTranscriptionRedeemResponse.self,
                from: Data(json.utf8)
            )
        }

        #expect(try decode("credited").outcome == .credited)
        #expect(try decode("already_credited").outcome == .alreadyCredited)
        #expect(try decode("refunded").outcome == .refunded)
        let unknown = try decode("mystery_future_outcome").outcome
        #expect(unknown == .unknown("mystery_future_outcome"))

        // Fail closed: only known acknowledgements may finish a transaction.
        #expect(OpenCastRemoteTranscriptionRedeemOutcome.credited.isFinishable)
        #expect(OpenCastRemoteTranscriptionRedeemOutcome.alreadyCredited.isFinishable)
        #expect(OpenCastRemoteTranscriptionRedeemOutcome.refunded.isFinishable)
        #expect(!unknown.isFinishable)
    }

    @Test("Purchase error codes round-trip their wire values")
    func purchaseErrorCodes() {
        #expect(OpenCastRemoteTranscriptionErrorCode(wireValue: "bootstrap_required") == .bootstrapRequired)
        #expect(OpenCastRemoteTranscriptionErrorCode(wireValue: "purchases_disabled") == .purchasesDisabled)
        #expect(OpenCastRemoteTranscriptionErrorCode.bootstrapRequired.wireValue == "bootstrap_required")
        #expect(OpenCastRemoteTranscriptionErrorCode.purchasesDisabled.wireValue == "purchases_disabled")
    }
}

/// Minimal JSON value for asserting encoded shapes without dictionary casts.
enum OpenCastRemoteTranscriptionAnyJSON: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}
