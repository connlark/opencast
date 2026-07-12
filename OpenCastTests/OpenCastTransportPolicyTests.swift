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

    @Test("Permits only the static ad-free continued processing task identifier")
    func permitsAdFreeContinuedProcessingTaskIdentifier() throws {
        let permittedIdentifiers = try #require(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )
        let backgroundModes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )

        #expect(permittedIdentifiers == ["com.connor.opencast.ad-free-pass"])
        #expect(!backgroundModes.contains("processing"))
    }
}
