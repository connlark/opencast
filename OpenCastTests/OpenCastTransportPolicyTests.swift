import Foundation
import Testing

@Suite("OpenCast transport policy")
struct OpenCastTransportPolicyTests {
    @Test("Allows user-provided HTTP podcast URLs")
    func allowsUserProvidedHTTPPodcastURLs() throws {
        let transportSecurity = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )

        #expect(transportSecurity["NSAllowsArbitraryLoads"] as? Bool == true)
    }
}
