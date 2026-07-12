#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import OpenCast

@MainActor
final class AdAnalysisAppAttestFixtureCaptureTests: XCTestCase {
    private static let captureEnvironmentKey = "OPENCAST_CAPTURE_AD_ANALYSIS_APP_ATTEST_FIXTURE"
    private static let invalidEnvironmentProbeKey =
        "OPENCAST_RUN_PROD_STAGING_INVALID_ENVIRONMENT_APP_ATTEST_TEST"
    private static let baseURLEnvironmentKey = "OPENCAST_AD_ANALYSIS_BASE_URL"
    private static let appIDEnvironmentKey = "OPENCAST_APP_ATTEST_APP_ID"
    private static let defaultBaseURL = URL(string: "https://ad-analysis.example.com/development")!
    private static let analyzePath = "/v1/ad-analysis/transcript"

    func testOptInCaptureDevelopmentAppAttestAnalyzeFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let shouldCapture: Bool
        #if OPENCAST_CAPTURE_AD_ANALYSIS_APP_ATTEST_FIXTURE
        shouldCapture = true
        #else
        shouldCapture = environment[Self.captureEnvironmentKey] == "1"
        #endif

        guard shouldCapture else {
            throw XCTSkip("Set \(Self.captureEnvironmentKey)=1 or build with -DOPENCAST_CAPTURE_AD_ANALYSIS_APP_ATTEST_FIXTURE on a physical device to capture an ad-analysis App Attest fixture.")
        }
        guard let appID = environment[Self.appIDEnvironmentKey], !appID.isEmpty else {
            throw XCTSkip("Set \(Self.appIDEnvironmentKey) to your App Attest app ID before capturing a fixture.")
        }

        let appAttestService = DeviceCheckAppAttestService.shared
        guard appAttestService.isSupported else {
            throw XCTSkip("App Attest is not supported on this device.")
        }

        let baseURL = environment[Self.baseURLEnvironmentKey]
            .flatMap(URL.init(string:))
            ?? Self.defaultBaseURL
        let configuration = AppAttestClientConfiguration(
            baseURL: baseURL,
            keychainService: "com.connor.opencast.ad-analysis-security.fixture-capture"
        )
        let apiClient = AppAttestAPIClient(configuration: configuration)
        let installID = "fixture-\(UUID().uuidString)"
        let keyID = try await appAttestService.generateKey()
        let challenge = try await apiClient.requestChallenge(installID: installID)
        let challengeHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let attestationObject = try await appAttestService.attestKey(
            keyID,
            clientDataHash: challengeHash
        )
        let registerMessage = try await apiClient.register(
            installID: installID,
            keyID: keyID,
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            attestationObject: attestationObject
        )

        let request = makeFixtureRequest()
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request)
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: Self.analyzePath,
            payload: payload
        )
        let assertion = try await appAttestService.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )

        let response: EpisodeAdAnalysisAPIResponse?
        #if OPENCAST_CAPTURE_AD_ANALYSIS_APP_ATTEST_FIXTURE_SKIP_ANALYZE
        response = nil
        #else
        response = try await apiClient.sendAuthenticatedEnvelope(
            path: Self.analyzePath,
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion,
            response: EpisodeAdAnalysisAPIResponse.self
        )
        XCTAssertEqual(response?.requestID, request.requestID)
        #endif

        let fixture = CapturedAdAnalysisAppAttestFixture(
            appID: appID,
            environment: "development",
            installID: installID,
            keyID: keyID,
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            attestationObject: attestationObject.base64EncodedString(),
            method: "POST",
            path: Self.analyzePath,
            payload: payload,
            assertion: assertion.base64EncodedString(),
            previousCounter: 0,
            capturedAtSeconds: Int(Date().timeIntervalSince1970),
            clientDataHashSHA256Hex: AppAttestRequestBinding.hexString(clientDataHash),
            registerMessage: registerMessage,
            responseRequestID: response?.requestID,
            responseSpanCount: response?.spans.count
        )
        let data = try Self.fixtureEncoder.encode(fixture)
        let json = String(decoding: data, as: UTF8.self)

        print("OPENCAST_AD_ANALYSIS_APP_ATTEST_FIXTURE_BEGIN")
        print(json)
        print("OPENCAST_AD_ANALYSIS_APP_ATTEST_FIXTURE_END")

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "ad_analysis_app_attest_development_fixture.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOptInCachedProdStagingAppAttestKeyRejectsInvalidEnvironment() async throws {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        let shouldRunProbe: Bool
        #if OPENCAST_RUN_PROD_STAGING_INVALID_ENVIRONMENT_APP_ATTEST_TEST
        shouldRunProbe = true
        #else
        shouldRunProbe = ProcessInfo.processInfo.environment[Self.invalidEnvironmentProbeKey] == "1"
        #endif

        guard shouldRunProbe else {
            throw XCTSkip("Set \(Self.invalidEnvironmentProbeKey)=1 or build with -DOPENCAST_RUN_PROD_STAGING_INVALID_ENVIRONMENT_APP_ATTEST_TEST to run the prod-staging invalid-environment proof.")
        }

        guard DCAppAttestService.shared.isSupported else {
            throw XCTSkip("App Attest is not supported on this device.")
        }

        let appAttestConfiguration = AppAttestClientConfiguration(
            baseURL: AdAnalysisBackendConfiguration.prodStaging.workerBaseURL,
            keychainService: AdAnalysisAppAttestKeychainServices.prodStaging
        )
        let apiClient = AppAttestAPIClient(configuration: appAttestConfiguration)
        let keychain = AppAttestKeychain(service: appAttestConfiguration.keychainService)
        let credentialService = AppAttestCredentialService(
            apiClient: apiClient,
            keychain: keychain
        )
        let credential = try XCTUnwrap(
            try credentialService.loadRegisteredCredential(),
            "Expected the preceding prod-staging App Attest proof to leave a cached credential."
        )
        let secureClient = AppAttestSecureAPIClient(
            apiClient: apiClient,
            appAttestService: DeviceCheckAppAttestService.shared
        )
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(makeFixtureRequest())
        do {
            _ = try await secureClient.sendRawPayload(
                path: Self.analyzePath,
                installID: credential.installID,
                keyID: credential.keyID,
                payload: payload,
                response: EpisodeAdAnalysisAPIResponse.self
            )
            XCTFail("Expected prod-staging to reject the cached key with invalid_environment.")
        } catch let error as AppAttestHTTPError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.code, "invalid_environment")
        }
        #else
        throw XCTSkip("The invalid-environment proof requires OpenCastNotificationsInternal.")
        #endif
    }

    private static var fixtureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func makeFixtureRequest() -> EpisodeAdAnalysisAPIRequest {
        EpisodeAdAnalysisAPIRequest(
            schemaVersion: 1,
            requestID: "app-attest-fixture-\(UUID().uuidString)",
            episodeID: "fixture-episode",
            podcastID: "https://example.com/fixture-feed.xml",
            episodeTitle: "Fixture Episode",
            podcastTitle: "Fixture Podcast",
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: "en",
                audioDuration: 45,
                modelIdentifier: "fixture-model",
                modelVersion: "v1",
                modelTreeSHA256: "fixture-tree-sha",
                fingerprint: "fixture-fingerprint",
                updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                state: "completed",
                segmentCount: 3
            ),
            segments: [
                EpisodeAdAnalysisAPISegment(
                    id: 1,
                    start: 0,
                    end: 8,
                    text: "Welcome back to the fixture episode."
                ),
                EpisodeAdAnalysisAPISegment(
                    id: 2,
                    start: 8,
                    end: 24,
                    text: "This episode is brought to you by Seed Sponsor, the dependable sponsor for this test."
                ),
                EpisodeAdAnalysisAPISegment(
                    id: 3,
                    start: 24,
                    end: 45,
                    text: "Visit Seed Sponsor after the show for the offer, and now back to the episode."
                )
            ]
        )
    }
}

private struct CapturedAdAnalysisAppAttestFixture: Encodable {
    var appID: String
    var environment: String
    var installID: String
    var keyID: String
    var challengeID: String
    var challenge: String
    var attestationObject: String
    var method: String
    var path: String
    var payload: String
    var assertion: String
    var previousCounter: Int
    var capturedAtSeconds: Int
    var clientDataHashSHA256Hex: String
    var registerMessage: String
    var responseRequestID: String?
    var responseSpanCount: Int?

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case environment
        case installID = "install_id"
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case challenge
        case attestationObject = "attestation_object"
        case method
        case path
        case payload
        case assertion
        case previousCounter = "previous_counter"
        case capturedAtSeconds = "captured_at_seconds"
        case clientDataHashSHA256Hex = "client_data_hash_sha256_hex"
        case registerMessage = "register_message"
        case responseRequestID = "response_request_id"
        case responseSpanCount = "response_span_count"
    }
}
#endif
