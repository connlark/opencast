import CryptoKit
import Foundation
import XCTest
@testable import OpenCast

final class EpisodeAdAnalysisProductionDeviceTests: XCTestCase {
    func testProductionAppAttestLongEpisodeReturnsAcceptedAndCompletes() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Production App Attest verification requires a physical device.")
        #else
        guard ProcessInfo.processInfo.environment["OPENCAST_PRODUCTION_AD_ANALYSIS_E2E"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_PRODUCTION_AD_ANALYSIS_E2E=1 to run this paid live test.")
        }

        let fingerprint = SHA256.hash(data: Data(UUID().uuidString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let request = EpisodeAdAnalysisAPIRequest(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            requestID: UUID().uuidString,
            episodeID: "production-device-\(UUID().uuidString)",
            podcastID: "https://example.com/opencast-production-device.xml",
            episodeTitle: "OpenCast production App Attest verification",
            podcastTitle: "OpenCast verification",
            asyncSupported: true,
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: "en",
                audioDuration: 8_400,
                modelIdentifier: "production-device-fixture",
                modelVersion: "v1",
                modelTreeSHA256: nil,
                fingerprint: fingerprint,
                updatedAt: .now,
                state: EpisodeAdAnalysisContract.completedTranscriptState,
                segmentCount: 2_100
            ),
            segments: (0..<2_100).map { id in
                EpisodeAdAnalysisAPISegment(
                    id: id,
                    start: TimeInterval(id * 4),
                    end: TimeInterval((id + 1) * 4),
                    text: Self.segmentText(id: id)
                )
            }
        )
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: .production
        )

        let submitOutcome = try await client.analyze(request)
        let initialPollAfter: TimeInterval
        switch submitOutcome {
        case .accepted(let jobID, let pollAfter):
            XCTAssertEqual(jobID, fingerprint)
            initialPollAfter = pollAfter
        case .completed:
            XCTFail("A fresh 2,100-segment request must use the asynchronous 202 contract.")
            return
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        var pollAfter = initialPollAfter
        while clock.now < deadline {
            try await Task.sleep(for: .seconds(min(max(pollAfter, 0), 120)))
            switch try await client.pollJob(id: fingerprint) {
            case .running(let nextPollAfter):
                pollAfter = nextPollAfter
            case .completed(let response):
                XCTAssertEqual(response.schemaVersion, EpisodeAdAnalysisContract.schemaVersion)
                XCTAssertEqual(response.policy, EpisodeAdAnalysisContract.expectedPolicy)
                XCTAssertFalse(response.spans.isEmpty)
                return
            }
        }

        XCTFail("Production ad-analysis job did not complete within ten minutes.")
        #endif
    }

    private static func segmentText(id: Int) -> String {
        switch id {
        case 2:
            "This episode is brought to you by OpenCast Verification Sponsor."
        case 3:
            "OpenCast Verification Sponsor helps teams test reliable software."
        case 4:
            "Visit example dot com slash opencast and use offer code TEST."
        case 5:
            "Thanks to OpenCast Verification Sponsor for supporting this show."
        case 1_802:
            "We will pause for another message from Long Episode Sponsor."
        case 1_803:
            "Long Episode Sponsor makes dependable tools for long-running jobs."
        case 1_804:
            "Learn more at example dot com slash long episode."
        case 1_805:
            "Thanks again to Long Episode Sponsor, and now back to the show."
        default:
            "Regular podcast discussion segment \(id) with no commercial message."
        }
    }
}
