import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad analysis cap classification")
struct EpisodeAdAnalysisCapClassificationTests {
    @Test(
        "429 with a worker cap code classifies as cap-exceeded; everything else does not",
        arguments: [
            (429, "daily_request_cap_exceeded", true),
            (429, "daily_input_token_cap_exceeded", true),
            (429, "global_capacity_exhausted", true),
            (500, "daily_request_cap_exceeded", false),
            (429, "rate_limited_other", false)
        ]
    )
    func capClassificationTable(statusCode: Int, code: String, isCapExceeded: Bool) {
        #expect(EpisodeAdAnalysisHTTPError(statusCode: statusCode, code: code, detail: nil).isCapExceeded == isCapExceeded)
    }
}
