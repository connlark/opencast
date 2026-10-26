import Foundation
import Testing
@testable import OpenCast

@Suite("Trial service configuration")
struct TrialProxyBackendConfigurationTests {
    static let bundleEndpoint = URL(string: "https://trial.opencast.mobile")!

    #if DEBUG
    @Test("Debug builds use the development deployment with its own slot, or an origin override")
    func debugDefaultsAndOverride() {
        let plain = TrialProxyBackendConfiguration.debug(environment: [:])
        #expect(plain.baseURL == TrialProxyBackendConfiguration.developmentBaseURL)
        #expect(plain.authentication == .appAttest(keychainService: TrialProxyAppAttestKeychainServices.development))

        let overridden = TrialProxyBackendConfiguration.debug(environment: ["OPENCAST_TRIAL_PROXY_BASE_URL": "http://127.0.0.1:8787"])
        #expect(overridden.baseURL == URL(string: "http://127.0.0.1:8787"))
        #expect(overridden.authentication == .appAttest(keychainService: TrialProxyAppAttestKeychainServices.development))

        // An override the request binding could not sign falls back to the development deployment.
        for value in ["https://trial.example/prefix", "https://trial.example?deployment=x", "ftp://trial.example", "", "   "] {
            let configuration = TrialProxyBackendConfiguration.debug(environment: ["OPENCAST_TRIAL_PROXY_BASE_URL": value])
            #expect(configuration.baseURL == TrialProxyBackendConfiguration.developmentBaseURL, "\(value)")
        }
    }

    @Test("A Debug operator bearer signs instead of App Attest; a blank one does not")
    func debugBearer() {
        let token = ["fixture", "-bearer-", "for-tests"].joined()
        let bearer = TrialProxyBackendConfiguration.debug(environment: [
            "OPENCAST_TRIAL_PROXY_CLIENT_TOKEN": "  \(token)\n",
            "OPENCAST_TRIAL_PROXY_BASE_URL": "https://deployment.example/",
        ])
        #expect(bearer.authentication == .bearer(clientToken: token))
        #expect(bearer.baseURL == URL(string: "https://deployment.example"))
        #expect(bearer.canAuthenticate(appAttestSupported: false))

        let blank = TrialProxyBackendConfiguration.debug(environment: ["OPENCAST_TRIAL_PROXY_CLIENT_TOKEN": "   "])
        #expect(blank.authentication == .appAttest(keychainService: TrialProxyAppAttestKeychainServices.development))
    }
    #endif

    @Test("Release builds map each store environment to its deployment and slot")
    func releasePerEnvironment() throws {
        let production = try #require(TrialProxyBackendConfiguration.release(for: .production, trialEndpoint: Self.bundleEndpoint))
        #expect(production.baseURL == Self.bundleEndpoint)
        #expect(production.authentication == .appAttest(keychainService: TrialProxyAppAttestKeychainServices.production))

        for environment: RemoteTranscriptionStoreEnvironment in [.sandbox, .xcode] {
            let staging = try #require(TrialProxyBackendConfiguration.release(for: environment, trialEndpoint: Self.bundleEndpoint))
            #expect(staging == .prodStaging)
            #expect(staging.baseURL == TrialProxyBackendConfiguration.prodStagingBaseURL)
            #expect(staging.authentication == .appAttest(keychainService: TrialProxyAppAttestKeychainServices.prodStaging))
        }

        #expect(TrialProxyBackendConfiguration.release(for: .unknown("LocalTesting"), trialEndpoint: Self.bundleEndpoint) == nil)
    }

    @Test("Production needs the bundle's endpoint to be an https origin")
    func productionEndpointRules() {
        for endpoint in ["http://trial.opencast.mobile", "https://trial.opencast.mobile/v1", "https://trial.opencast.mobile?x=1"] {
            let url = URL(string: endpoint)!
            #expect(TrialProxyBackendConfiguration.release(for: .production, trialEndpoint: url) == nil, "\(endpoint)")
        }
        let withPort = TrialProxyBackendConfiguration.release(for: .production, trialEndpoint: URL(string: "https://trial.opencast.mobile:8443/")!)
        #expect(withPort?.baseURL == URL(string: "https://trial.opencast.mobile:8443"))
    }

    @Test("An origin URL has a scheme and host only: path, query, fragment and user info are refused", arguments: [
        ("https://trial.example", "https://trial.example"),
        ("https://trial.example/", "https://trial.example"),
        ("HTTPS://trial.example", "https://trial.example"),
        ("http://localhost:8787", "http://localhost:8787"),
        ("  https://trial.example  ", "https://trial.example"),
        ("https://trial.example/v1", nil),
        ("https://trial.example/v1/trial/analyze", nil),
        ("https://trial.example?deployment=a", nil),
        ("https://trial.example#top", nil),
        ("https://user@trial.example", nil),
        ("https://user:secret@trial.example", nil),
        ("ftp://trial.example", nil),
        ("trial.example", nil),
        ("https://", nil),
        ("", nil),
    ] as [(String, String?)])
    func originRules(value: String, expected: String?) {
        #expect(TrialProxyBackendConfiguration.originURL(value)?.absoluteString == expected)
    }

    @Test("App Attest signs only where the device can attest")
    func canAuthenticate() {
        let attested = TrialProxyBackendConfiguration.prodStaging
        #expect(attested.canAuthenticate(appAttestSupported: true))
        #expect(!attested.canAuthenticate(appAttestSupported: false))
    }

    @Test("Each deployment has its own slot, distinct from the other services' slots")
    func slotsAreDistinct() {
        let slots = TrialProxyAppAttestKeychainServices.all
        #expect(slots.count == 3)
        #expect(Set(slots).count == 3)
        let others = AdAnalysisAppAttestKeychainServices.all
            + TranscriptAnalysisAppAttestKeychainServices.all
            + RemoteTranscriptionAppAttestKeychainServices.all
        #expect(Set(slots).isDisjoint(with: others))
    }
}
