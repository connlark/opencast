import Foundation
@testable import OpenCastTranscription
import Testing

@Suite("OpenCast transcription resources")
struct OpenCastTranscriptionResourceTests {
    @Test("No transcription models are bundled")
    func noTranscriptionModelsAreBundled() {
        #expect(Bundle.module.url(forResource: "Models", withExtension: nil) == nil)
        #expect(Bundle.module.url(forResource: "Tokenizers", withExtension: nil) == nil)
    }

    @Test("License resources remain bundled")
    func licenseResourcesRemainBundled() throws {
        let licenseURL = try #require(Bundle.module.url(
            forResource: "OpenAI-Whisper-LICENSE",
            withExtension: nil,
            subdirectory: "Licenses"
        ))

        #expect(FileManager.default.fileExists(atPath: licenseURL.path))
    }
}
