@testable import OpenCastAnalysisProviders
import Testing

@Suite("Provider limits")
struct ProviderLimitsTests {
    @Test("The response cap equals both analysis services' Gemini body cap")
    func responseCap() throws {
        let chapters = try TestSupport.repositoryText("Server/TranscriptAnalysisWorker/src/analysis.rs")
        #expect(chapters.contains("const MAX_GEMINI_RESPONSE_BYTES: usize = 512 * 1024;"))
        let ads = try TestSupport.repositoryText("Server/AdAnalysisWorker/src/analysis.rs")
        #expect(ads.contains("bytes.len().saturating_add(chunk.len()) > 512 * 1024"))
        #expect(AnalysisProviderLimits.maxResponseBytes == 512 * 1024)
    }
}
