import Foundation
import Testing
@testable import OpenCastTranscription

struct AdAnalysisFailureTests {
    @Test func typedAndLegacyFailureEnvelopesRemainReadable() throws {
        let failure = OpenCastAdAnalysisFailure(category: .validationExhausted, retryDisposition: .explicitRetry, policyRevision: "revision-a")
        let outcome = OpenCastRemoteTranscriptionAdAnalysisOutcome.failed(errorCode: "ad_analysis_incomplete", failure: failure)
        #expect(try JSONDecoder().decode(OpenCastRemoteTranscriptionAdAnalysisOutcome.self, from: JSONEncoder().encode(outcome)) == outcome)
        #expect(failure.suppressesAutomaticReplay)
        #expect(!OpenCastAdAnalysisFailure(category: .capacity, retryDisposition: .afterCapacity).suppressesAutomaticReplay)
        let old = Data(#"{"state":"failed","error_code":"ad_analysis_failed"}"#.utf8)
        #expect(try JSONDecoder().decode(OpenCastRemoteTranscriptionAdAnalysisOutcome.self, from: old) == .failed(errorCode: "ad_analysis_failed"))
        let future = Data(#"{"state":"failed","error_code":"ad_analysis_incomplete","failure":{"category":"future","retry_disposition":"future"}}"#.utf8)
        #expect(try JSONDecoder().decode(OpenCastRemoteTranscriptionAdAnalysisOutcome.self, from: future) == .failed(errorCode: "ad_analysis_incomplete"))
    }
}
