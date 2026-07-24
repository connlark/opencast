import Foundation
import Testing
@testable import OpenCastTranscription

@Suite("Remote transcription wire types")
struct OpenCastRemoteTranscriptionWireTests {
    @Test("Job response decodes snake_case JSON")
    func jobResponseDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "job": {
            "job_id": "job-abc123",
            "state": "transcribing",
            "episode_id": "ep-hash-1",
            "progress": {
              "chunks_completed": 3,
              "chunks_total": 7,
              "estimated_remaining_seconds": 52,
              "estimate_status": "on_track"
            },
            "created_at": "2026-07-16T12:00:00Z",
            "updated_at": "2026-07-16T12:03:00Z"
          },
          "balance": {
            "available_seconds": 32400,
            "reserved_seconds": 2040,
            "debt_seconds": 0
          }
        }
        """
        let response = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionJobResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.schemaVersion == 1)
        #expect(response.job.jobID == "job-abc123")
        #expect(response.job.state == .transcribing)
        #expect(response.job.episodeID == "ep-hash-1")
        #expect(response.job.progress?.chunksCompleted == 3)
        #expect(response.job.progress?.chunksTotal == 7)
        #expect(response.job.progress?.estimatedRemainingSeconds == 52)
        #expect(response.job.progress?.estimateStatus == .onTrack)
        #expect(response.balance?.availableSeconds == 32400)
        #expect(response.balance?.reservedSeconds == 2040)
        #expect(response.job.state.isTerminal == false)
    }

    @Test("Progress estimate fields are optional for older Workers")
    func legacyProgressDecodesWithoutEstimate() throws {
        let progress = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionJobProgress.self,
            from: Data(#"{"chunks_completed":1,"chunks_total":4}"#.utf8)
        )
        #expect(progress.chunksCompleted == 1)
        #expect(progress.chunksTotal == 4)
        #expect(progress.estimatedRemainingSeconds == nil)
        #expect(progress.estimateStatus == nil)
    }

    @Test("Estimate statuses preserve known and unknown wire values")
    func estimateStatusesRoundTrip() throws {
        let known: [OpenCastRemoteTranscriptionEstimateStatus] = [
            .onTrack, .queued, .delayed,
        ]
        for status in known {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(
                OpenCastRemoteTranscriptionEstimateStatus.self,
                from: data
            ) == status)
        }

        let unknown = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionEstimateStatus.self,
            from: Data(#""recalculating""#.utf8)
        )
        #expect(unknown == .unknown("recalculating"))
        let roundTrip = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionEstimateStatus.self,
            from: JSONEncoder().encode(unknown)
        )
        #expect(roundTrip == unknown)
    }

    @Test("Unknown job state is preserved through reencoding")
    func unknownStateRoundTrips() throws {
        let json = """
        { "job_id": "job-1", "state": "quantum_flux" }
        """
        let status = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionJobStatus.self,
            from: Data(json.utf8)
        )
        #expect(status.state == .unknown("quantum_flux"))
        #expect(status.state.isTerminal == false)
        let reencoded = try JSONEncoder().encode(status)
        let decodedAgain = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionJobStatus.self,
            from: reencoded
        )
        #expect(decodedAgain.state == .unknown("quantum_flux"))
    }

    @Test("Every known state round-trips its wire value")
    func knownStatesRoundTrip() {
        let states: [OpenCastRemoteTranscriptionJobState] = [
            .created, .stagingOrigin, .waitingForDeviceSource, .sourceMatched,
            .exactUploadRequired, .probing, .awaitingCredits, .reserved,
            .chunking, .transcribing, .stitching, .resultReady, .delivered,
            .acknowledged, .cancelling, .cancelled, .failed,
        ]
        for state in states {
            #expect(OpenCastRemoteTranscriptionJobState(wireValue: state.wireValue) == state)
        }
        #expect(states.count(where: \.isTerminal) == 3)
    }

    @Test("Error codes decode, preserve unknowns, and keep the mismatch code stable")
    func errorCodes() throws {
        #expect(
            OpenCastRemoteTranscriptionErrorCode(wireValue: "remote_unavailable_source_mismatch")
                == .sourceMismatch
        )
        #expect(OpenCastRemoteTranscriptionErrorCode.sourceMismatch.wireValue
            == "remote_unavailable_source_mismatch")

        let json = """
        { "code": "flux_capacitor_drained", "message": "try 1955" }
        """
        let error = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionJobError.self,
            from: Data(json.utf8)
        )
        #expect(error.code == .unknown("flux_capacitor_drained"))
        #expect(error.message == "try 1955")
        let reencoded = try JSONEncoder().encode(error)
        #expect(String(decoding: reencoded, as: UTF8.self).contains("flux_capacitor_drained"))
    }

    @Test("Result payload decodes segments with nested words")
    func resultDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "result": {
            "schema_version": 1,
            "source_identity": {
              "sha256": "da26a00f",
              "byte_count": 16328368,
              "duration_seconds": 2040.0
            },
            "language_code": "en",
            "duration_seconds": 2040.0,
            "text": "hello world",
            "segments": [
              {
                "id": 0,
                "start": 0.0,
                "end": 2.5,
                "text": "hello world",
                "words": [
                  { "start": 0.1, "end": 0.9, "text": "hello" },
                  { "start": 1.0, "end": 2.4, "text": "world" }
                ]
              }
            ],
            "provenance": {
              "provider": "cloudflare-workers-ai",
              "model_identifier": "@cf/openai/whisper-large-v3-turbo",
              "serving_contract_version": "1",
              "request_settings_sha256": "aa",
              "chunk_manifest_sha256": "bb",
              "normalized_transcript_sha256": "cc",
              "pipeline_version": "pass0"
            },
            "warnings": []
          }
        }
        """
        let response = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionResultResponse.self,
            from: Data(json.utf8)
        )
        let result = response.result
        #expect(result.sourceIdentity.byteCount == 16_328_368)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].words?.count == 2)
        #expect(result.segments[0].words?[1].text == "world")
        #expect(result.provenance.modelRevision == nil)
        #expect(result.provenance.modelIdentifier == "@cf/openai/whisper-large-v3-turbo")
    }

    @Test("Requests encode with snake_case keys and current schema version")
    func requestsEncode() throws {
        let create = OpenCastRemoteTranscriptionJobCreateRequest(
            clientRequestID: "11111111-2222-3333-4444-555555555555",
            episodeID: "ep-hash-1",
            enclosureURL: "https://example.com/audio.mp3",
            declaredDurationSeconds: 2040,
            languageCode: "en",
            sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity(
                sha256: "da26a00f",
                byteCount: 16_328_368
            )
        )
        #expect(create.schemaVersion == OpenCastRemoteTranscriptionSchema.version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(create), as: UTF8.self)
        #expect(encoded.contains("\"client_request_id\""))
        #expect(encoded.contains("\"episode_id\""))
        #expect(encoded.contains("\"enclosure_url\""))
        #expect(encoded.contains("\"schema_version\":1"))
        #expect(encoded.contains("\"byte_count\":16328368"))

        let bootstrap = OpenCastRemoteTranscriptionBootstrapRequest()
        let bootstrapJSON = String(decoding: try encoder.encode(bootstrap), as: UTF8.self)
        #expect(bootstrapJSON == "{\"schema_version\":1}")
    }

    @Test("Balance uses integer seconds")
    func balanceDecodes() throws {
        let json = """
        { "available_seconds": 36000, "reserved_seconds": 0, "debt_seconds": 0 }
        """
        let balance = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionBalance.self,
            from: Data(json.utf8)
        )
        #expect(balance.availableSeconds == 36000)
        #expect(balance.debtSeconds == 0)
    }

    @Test("Upload grant response decodes geometry and bounded part batches")
    func uploadGrantDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "upload_key_id": "mp-abc",
          "part_size_bytes": 16777216,
          "part_count": 12,
          "parts": [
            { "part_number": 1, "url": "https://r2.example/part?partNumber=1", "expires_at": 1784300000 },
            { "part_number": 2, "url": "https://r2.example/part?partNumber=2", "expires_at": 1784300000 }
          ]
        }
        """
        let grant = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionUploadGrantResponse.self,
            from: Data(json.utf8)
        )
        #expect(grant.uploadKeyID == "mp-abc")
        #expect(grant.partSizeBytes == 16_777_216)
        #expect(grant.partCount == 12)
        #expect(grant.parts.count == 2)
        #expect(grant.parts[1].partNumber == 2)
        #expect(grant.parts[1].expiresAt == 1_784_300_000)
    }

    @Test("Upload requests encode snake_case bodies")
    func uploadRequestsEncode() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let start = OpenCastRemoteTranscriptionUploadStartRequest(forBackground: true)
        let startJSON = String(decoding: try encoder.encode(start), as: UTF8.self)
        #expect(startJSON == "{\"for_background\":true,\"schema_version\":1}")

        let parts = OpenCastRemoteTranscriptionUploadPartsRequest(partNumbers: [3, 4])
        let partsJSON = String(decoding: try encoder.encode(parts), as: UTF8.self)
        #expect(partsJSON == "{\"part_numbers\":[3,4],\"schema_version\":1}")

        let complete = OpenCastRemoteTranscriptionUploadCompleteRequest(parts: [
            OpenCastRemoteTranscriptionUploadCompletedPart(partNumber: 1, etag: "abc123"),
        ])
        let completeJSON = String(decoding: try encoder.encode(complete), as: UTF8.self)
        #expect(completeJSON.contains("\"part_number\":1"))
        #expect(completeJSON.contains("\"etag\":\"abc123\""))
    }

    @Test("Upload states and error codes ride the stable-string contract")
    func uploadStatesAndCodes() {
        #expect(OpenCastRemoteTranscriptionJobState(wireValue: "exact_uploading") == .exactUploading)
        #expect(OpenCastRemoteTranscriptionJobState.exactUploading.isTerminal == false)
        #expect(OpenCastRemoteTranscriptionErrorCode(wireValue: "upload_unavailable") == .uploadUnavailable)
        #expect(OpenCastRemoteTranscriptionErrorCode(wireValue: "upload_identity_mismatch") == .uploadIdentityMismatch)
        #expect(OpenCastRemoteTranscriptionErrorCode.uploadUnavailable.wireValue == "upload_unavailable")
    }

    @Test("Detect-ads create fields encode when set and are omitted when nil")
    func adAnalysisCreateFieldsEncode() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let plain = OpenCastRemoteTranscriptionJobCreateRequest(
            clientRequestID: "req-1",
            episodeID: "ep-hash-1",
            enclosureURL: "https://example.com/audio.mp3"
        )
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("ad_analysis_requested"))
        #expect(!plainJSON.contains("podcast_id"))
        #expect(!plainJSON.contains("episode_title"))
        #expect(!plainJSON.contains("podcast_title"))

        let detect = OpenCastRemoteTranscriptionJobCreateRequest(
            clientRequestID: "req-2",
            episodeID: "ep-hash-1",
            enclosureURL: "https://example.com/audio.mp3",
            adAnalysisRequested: true,
            podcastID: "https://example.com/feed.xml",
            episodeTitle: "Episode 42",
            podcastTitle: "The Example Show"
        )
        let detectJSON = String(decoding: try encoder.encode(detect), as: UTF8.self)
        #expect(detectJSON.contains("\"ad_analysis_requested\":true"))
        #expect(detectJSON.contains("\"podcast_id\":\"https:\\/\\/example.com\\/feed.xml\""))
        #expect(detectJSON.contains("\"episode_title\":\"Episode 42\""))
        #expect(detectJSON.contains("\"podcast_title\":\"The Example Show\""))
    }

    @Test("detecting_ads is a known non-terminal state")
    func detectingAdsState() {
        #expect(OpenCastRemoteTranscriptionJobState(wireValue: "detecting_ads") == .detectingAds)
        #expect(OpenCastRemoteTranscriptionJobState.detectingAds.wireValue == "detecting_ads")
        #expect(OpenCastRemoteTranscriptionJobState.detectingAds.isTerminal == false)
    }

    @Test("Completed ad analysis decodes spans alongside an untouched result")
    func adAnalysisCompletedDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "result": \(Self.resultJSON),
          "ad_analysis": {
            "state": "completed",
            "schema_version": 1,
            "request_id": "job-abc123",
            "model": "gemini-3.5-flash",
            "policy": "promo_ad_breaks_v2",
            "spans": [
              {
                "kind": "host_read_ad",
                "label": "Mattress sponsor",
                "start_segment_id": 4,
                "end_segment_id": 9,
                "start_time": 61.5,
                "end_time": 122.0,
                "confidence": 0.92,
                "evidence_quote": "this episode is brought to you by"
              }
            ],
            "warnings": [],
            "usage": { "prompt_token_count": 100, "candidates_token_count": 20, "total_token_count": 120 }
          }
        }
        """
        let response = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionResultResponse.self,
            from: Data(json.utf8)
        )
        guard case let .completed(success) = response.adAnalysis else {
            Issue.record("expected completed outcome")
            return
        }
        #expect(success.model == "gemini-3.5-flash")
        #expect(success.policy == "promo_ad_breaks_v2")
        #expect(success.spans.count == 1)
        #expect(success.spans[0].kind == "host_read_ad")
        #expect(success.spans[0].startSegmentID == 4)
        #expect(success.spans[0].endTime == 122.0)
        #expect(response.result.text == "hello world")
    }

    @Test("Failed, absent, and unknown ad analysis outcomes decode safely")
    func adAnalysisFailureShapesDecode() throws {
        let decoder = JSONDecoder()

        let failed = try decoder.decode(
            OpenCastRemoteTranscriptionAdAnalysisOutcome.self,
            from: Data(#"{"state":"failed","error_code":"ad_analysis_capacity"}"#.utf8)
        )
        #expect(failed == .failed(errorCode: "ad_analysis_capacity"))

        let bareFailure = try decoder.decode(
            OpenCastRemoteTranscriptionAdAnalysisOutcome.self,
            from: Data(#"{"state":"failed"}"#.utf8)
        )
        #expect(bareFailure == .failed(errorCode: nil))

        let unknown = try decoder.decode(
            OpenCastRemoteTranscriptionAdAnalysisOutcome.self,
            from: Data(#"{"state":"deferred"}"#.utf8)
        )
        #expect(unknown == .unknown(state: "deferred"))

        let absent = try decoder.decode(
            OpenCastRemoteTranscriptionResultResponse.self,
            from: Data(#"{"schema_version":1,"result":\#(Self.resultJSON)}"#.utf8)
        )
        #expect(absent.adAnalysis == nil)
    }

    private static let resultJSON = """
    {
      "schema_version": 1,
      "source_identity": { "sha256": "da26a00f", "byte_count": 16328368, "duration_seconds": 2040.0 },
      "language_code": "en",
      "duration_seconds": 2040.0,
      "text": "hello world",
      "segments": [],
      "provenance": {
        "provider": "cloudflare-workers-ai",
        "model_identifier": "@cf/openai/whisper-large-v3-turbo",
        "serving_contract_version": "1",
        "request_settings_sha256": "aa",
        "chunk_manifest_sha256": "bb",
        "normalized_transcript_sha256": "cc",
        "pipeline_version": "pass0"
      },
      "warnings": []
    }
    """

    @Test("Provenance source match mode is additive and preserved")
    func provenanceSourceMatchMode() throws {
        let withMode = """
        {
          "provider": "cloudflare-workers-ai",
          "model_identifier": "@cf/openai/whisper-large-v3-turbo",
          "serving_contract_version": "1",
          "request_settings_sha256": "aa",
          "chunk_manifest_sha256": "bb",
          "normalized_transcript_sha256": "cc",
          "pipeline_version": "pass0",
          "source_match_mode": "exact_device_upload"
        }
        """
        let decoded = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionModelProvenance.self,
            from: Data(withMode.utf8)
        )
        #expect(decoded.sourceMatchMode == "exact_device_upload")

        // Pre-pass-2 servers omit the field entirely.
        let withoutMode = withMode.replacing(
            ",\n  \"source_match_mode\": \"exact_device_upload\"",
            with: ""
        )
        let legacy = try JSONDecoder().decode(
            OpenCastRemoteTranscriptionModelProvenance.self,
            from: Data(withoutMode.utf8)
        )
        #expect(legacy.sourceMatchMode == nil)
    }
}
