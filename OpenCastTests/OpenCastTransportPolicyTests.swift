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

    @Test("Permits only the static continued processing task identifiers")
    func permitsAdFreeContinuedProcessingTaskIdentifier() throws {
        let permittedIdentifiers = try #require(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )
        let backgroundModes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )

        #expect(permittedIdentifiers == [
            "com.connor.opencast.ad-free-pass",
            "com.connor.opencast.transcript-generation",
        ])
        #expect(!backgroundModes.contains("processing"))
    }
}
