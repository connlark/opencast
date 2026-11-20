import Foundation
import Testing
@testable import OpenCast

struct FeedTransportErrorClassifierTests {
    @Test(arguments: [
        URLError.Code.timedOut,
        .cannotFindHost,
        .dnsLookupFailed,
        .cannotConnectToHost,
        .networkConnectionLost,
        .badServerResponse,
        .secureConnectionFailed,
        .cancelled,
    ])
    func hostAmbiguousAndServerCodesStayOrdinary(code: URLError.Code) {
        #expect(!FeedTransportErrorClassifier.isUnreachable(URLError(code)))
    }
}
