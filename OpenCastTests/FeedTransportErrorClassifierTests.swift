import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

struct FeedTransportErrorClassifierTests {
    @Test(arguments: [
        URLError.Code.notConnectedToInternet,
        .dataNotAllowed,
        .internationalRoamingOff,
    ])
    func deviceSideCodesAreUnreachable(code: URLError.Code) {
        #expect(FeedTransportErrorClassifier.isUnreachable(URLError(code)))
    }

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

    @Test func nonTransportErrorsStayOrdinary() {
        #expect(!FeedTransportErrorClassifier.isUnreachable(OpenCastCoreError.unexpectedStatusCode(503)))
        #expect(!FeedTransportErrorClassifier.isUnreachable(CancellationError()))
    }
}
