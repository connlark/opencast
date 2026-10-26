import Foundation
import Testing
@testable import OpenCast

/// A job an earlier build started can still end at the service's daily
/// limit; its failure keeps the cap kind for the card's copy.
@MainActor
@Suite("Ad analysis cap classification")
struct EpisodeAdAnalysisCapClassificationTests {
    @Test("429 with a worker cap code classifies as cap-exceeded; everything else does not")
    func capClassificationTable() {
        let capCodes = [
            "daily_request_cap_exceeded",
            "daily_input_token_cap_exceeded",
            "global_capacity_exhausted"
        ]
        for code in capCodes {
            #expect(EpisodeAdAnalysisHTTPError(statusCode: 429, code: code, detail: nil).isCapExceeded)
            // A cap code without the 429 status is not a cap rejection.
            #expect(!EpisodeAdAnalysisHTTPError(statusCode: 500, code: code, detail: nil).isCapExceeded)
        }
        #expect(!EpisodeAdAnalysisHTTPError(statusCode: 429, code: "rate_limited_other", detail: nil).isCapExceeded)
        #expect(!EpisodeAdAnalysisHTTPError(statusCode: 503, code: "overloaded", detail: nil).isCapExceeded)
    }
}
