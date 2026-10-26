import Foundation
@testable import OpenCastAnalysis
import Testing

/// The gateway's shared timestamp cases: the generator's relational check and
/// this decoder must agree on every one.
@Suite("Analysis policy timestamps")
struct AnalysisPolicyTimestampTests {
    private struct Cases: Decodable {
        struct Valid: Decodable {
            let value: String
            let unixSeconds: Int64

            enum CodingKeys: String, CodingKey {
                case value
                case unixSeconds = "unix_seconds"
            }
        }

        let valid: [Valid]
        let invalid: [String]
    }

    private static func cases() throws -> Cases {
        try JSONDecoder().decode(
            Cases.self,
            from: PolicyTestSupport.gatewayFile("tests/fixtures/analysis-policy-timestamps.json")
        )
    }

    @Test("Shared cases: canonical UTC accepted with the right instant, everything else refused")
    func sharedCases() throws {
        let cases = try Self.cases()
        #expect(!cases.valid.isEmpty && !cases.invalid.isEmpty)
        for valid in cases.valid {
            #expect(AnalysisPolicyTimestamp.unixSeconds(from: valid.value) == valid.unixSeconds, "\(valid.value)")
        }
        for invalid in cases.invalid {
            #expect(AnalysisPolicyTimestamp.unixSeconds(from: invalid) == nil, "\(invalid)")
        }
    }

    @Test("A bundle with any non-canonical timestamp does not decode")
    func bundleTimestampsAreChecked() throws {
        let baked = BakedAnalysisPolicy.json
        let generatedAt = try #require(baked.firstMatch(of: #/"generated_at": "([^"]*)"/#)?.output.1)
        for invalid in try Self.cases().invalid {
            let escaped = invalid.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
            for field in [#""generated_at": "\#(generatedAt)""#, #""starts_at": "2027-01-01T00:00:00Z""#] {
                let key = field.prefix(while: { $0 != ":" })
                let json = baked.replacing(field, with: "\(key): \"\(escaped)\"")
                #expect(json != baked)
                #expect(throws: (any Error).self, "\(key) \(invalid)") {
                    try AnalysisPolicyBundle.decode(Data(json.utf8))
                }
            }
        }
        let instant = try #require(ISO8601DateFormatter().date(from: String(generatedAt)))
        #expect(AnalysisPolicyBundle.baked.generatedAt == instant)
    }
}
