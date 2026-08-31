import AVFoundation
import CryptoKit
import Foundation
import OpenCastTranscription
import XCTest
@testable import OpenCast

/// Dev-lane harness: runs the real app-side upload engine —
/// `RemoteTranscriptionUploadSession` over `BackgroundRemoteTranscriptionUploadTransport`
/// and `RemoteTranscriptionAPIClient` — against the live development worker
/// end-to-end: create with a deliberately mismatched enclosure, ride
/// `exact_upload_required`, upload the local file through presigned parts,
/// and verify the delivered transcript settles with
/// `source_match_mode == exact_device_upload`. Replaces the earlier feasibility
/// probe that targeted the removed `/v1/dev-probe/r2-presign/*` routes.
/// Inert in normal runs: every test skips unless OPENCAST_R2_PROBE_PHASE
/// selects it (dev bearer required, spends dev-lane credits).
@MainActor
final class RemoteTranscriptionDevLaneUploadHarnessTests: XCTestCase {
    private static let defaultDecoyURL =
        "https://raw.githubusercontent.com/mathiasbynens/small/master/mp3.mp3"

    private struct HarnessEnvironment {
        let token: String
        let baseURL: String
        let audioURL: URL
        let decoyURL: String
        let stateDirectory: URL
    }

    private func requiredPhase(_ phase: String) throws {
        let current = ProcessInfo.processInfo.environment["OPENCAST_R2_PROBE_PHASE"]
        try XCTSkipUnless(current == phase, "dev-lane harness phase \(phase) not selected.")
    }

    private func makeEnvironment() throws -> HarnessEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["OPENCAST_R2_PROBE_TOKEN"], !token.isEmpty else {
            throw HarnessFailure("OPENCAST_R2_PROBE_TOKEN missing for selected phase")
        }
        guard let audioPath = environment["OPENCAST_R2_PROBE_AUDIO_PATH"], !audioPath.isEmpty else {
            throw HarnessFailure("OPENCAST_R2_PROBE_AUDIO_PATH missing for selected phase")
        }
        guard let statePath = environment["OPENCAST_R2_PROBE_STATE_PATH"], !statePath.isEmpty else {
            throw HarnessFailure("OPENCAST_R2_PROBE_STATE_PATH missing for selected phase")
        }
        let stateDirectory = URL(fileURLWithPath: statePath, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        return HarnessEnvironment(
            token: token,
            baseURL: environment["OPENCAST_R2_PROBE_BASE_URL"]
                ?? "https://remote-transcription.example.com/development",
            audioURL: URL(fileURLWithPath: audioPath),
            decoyURL: environment["OPENCAST_R2_PROBE_DECOY_URL"] ?? Self.defaultDecoyURL,
            stateDirectory: stateDirectory
        )
    }

    private func makeClient(_ harness: HarnessEnvironment) -> RemoteTranscriptionAPIClient {
        RemoteTranscriptionAPIClient(
            configuration: .debug(environment: [
                "OPENCAST_REMOTE_TRANSCRIPTION_BASE_URL": harness.baseURL,
                "OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN": harness.token,
            ]),
            appTransactionJWSProvider: { nil }
        )
    }

    func testDevLaneExactUploadSessionEndToEnd() async throws {
        try requiredPhase("session")
        let harness = try makeEnvironment()
        let client = makeClient(harness)

        let audioData = try Data(contentsOf: harness.audioURL, options: .mappedIfSafe)
        let sha256 = SHA256.hash(data: audioData)
            .map { String(format: "%02x", $0) }
            .joined()
        let byteCount = Int64(audioData.count)
        let duration = try await CMTimeGetSeconds(
            AVURLAsset(url: harness.audioURL).load(.duration)
        )
        XCTAssertGreaterThan(duration, 60, "harness audio implausibly short")

        // The decoy enclosure stages fine but hashes differently from the
        // local file, so the server must request the exact-device upload.
        let created = try await client.createJob(
            OpenCastRemoteTranscriptionJobCreateRequest(
                clientRequestID: UUID().uuidString.lowercased(),
                episodeID: "pass2-w6-sim-harness",
                enclosureURL: harness.decoyURL,
                declaredDurationSeconds: duration,
                languageCode: "en",
                sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity(
                    sha256: sha256,
                    byteCount: byteCount
                )
            )
        )
        let jobID = created.job.jobID
        var stateSequence: [String] = [created.job.state.wireValue]

        _ = try await pollUntil(
            client: client,
            jobID: jobID,
            states: [.exactUploadRequired],
            timeout: 180,
            sequence: &stateSequence
        )

        // Real engine, real transport: background-configured URLSession PUTs
        // against live presigned R2 URLs, part bookkeeping in UserDefaults.
        let localCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("w6-harness-\(jobID).mp3")
        try? FileManager.default.removeItem(at: localCopy)
        try FileManager.default.copyItem(at: harness.audioURL, to: localCopy)
        defer { try? FileManager.default.removeItem(at: localCopy) }

        let session = RemoteTranscriptionUploadSession(
            jobID: jobID,
            sourceFileURL: localCopy,
            api: client,
            transport: BackgroundRemoteTranscriptionUploadTransport(jobID: jobID)
        )
        var progressSamples: [[Int]] = []
        try await session.run { completed, total in
            progressSamples.append([completed, total])
        }
        XCTAssertEqual(progressSamples.last?.first, progressSamples.last?.last,
                       "final progress sample must report all parts complete")

        let settled = try await pollUntil(
            client: client,
            jobID: jobID,
            states: [.resultReady, .delivered],
            timeout: 1200,
            sequence: &stateSequence
        )
        XCTAssertFalse(settled.state.isTerminal)

        let result = try await client.result(jobID: jobID).result
        XCTAssertEqual(result.sourceIdentity.sha256, sha256)
        XCTAssertEqual(result.sourceIdentity.byteCount, byteCount)
        XCTAssertEqual(result.provenance.sourceMatchMode, "exact_device_upload")
        XCTAssertGreaterThan(result.text.count, 500, "transcript implausibly short")
        XCTAssertFalse(result.segments.isEmpty)

        _ = try await client.ack(jobID: jobID, normalizedTranscriptSHA256: nil)

        let evidence: [String: Any] = [
            "job_id": jobID,
            "state_sequence": stateSequence,
            "byte_count": byteCount,
            "duration_seconds": duration,
            "part_progress_samples": progressSamples,
            "text_chars": result.text.count,
            "segments": result.segments.count,
            "source_match_mode": result.provenance.sourceMatchMode ?? "",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: harness.stateDirectory.appendingPathComponent("session-result.json"))
    }

    private func pollUntil(
        client: RemoteTranscriptionAPIClient,
        jobID: String,
        states: Set<OpenCastRemoteTranscriptionJobState>,
        timeout: TimeInterval,
        sequence: inout [String]
    ) async throws -> OpenCastRemoteTranscriptionJobStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await client.poll(jobID: jobID)
            let job = response.job
            if sequence.last != job.state.wireValue {
                sequence.append(job.state.wireValue)
            }
            if states.contains(job.state) {
                return job
            }
            if job.state.isTerminal {
                throw HarnessFailure("job entered terminal \(job.state.wireValue): "
                    + (job.error?.code.wireValue ?? "no error"))
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw HarnessFailure("timed out waiting for \(states.map(\.wireValue).sorted())")
    }
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
