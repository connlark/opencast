import Testing
@testable import OpenCast

@Suite("Analysis provider key format")
struct AnalysisProviderKeyFormatTests {
    @Test("Whole keys, trimmed, are plausible")
    func wholeKeysArePlausible() {
        #expect(AnalysisProviderKeyFormat.isPlausible(AnalysisKeyFixtures.googleText))
        #expect(AnalysisProviderKeyFormat.isPlausible(AnalysisKeyFixtures.openAIText))
        #expect(AnalysisProviderKeyFormat.isPlausible("  \(AnalysisKeyFixtures.openAIText)\n"))
        #expect(AnalysisProviderKeyFormat.isPlausible(String(repeating: "k", count: 8)))
        #expect(AnalysisProviderKeyFormat.isPlausible(String(repeating: "k", count: 512)))
    }

    @Test("Fragments, multi-line copies and non-ASCII text are not")
    func implausibleTextIsRefused() {
        #expect(!AnalysisProviderKeyFormat.isPlausible(""))
        #expect(!AnalysisProviderKeyFormat.isPlausible("   \n"))
        #expect(!AnalysisProviderKeyFormat.isPlausible("sk-1234"))
        #expect(!AnalysisProviderKeyFormat.isPlausible(String(repeating: "k", count: 513)))
        #expect(!AnalysisProviderKeyFormat.isPlausible("first-half-of-key\nsecond-half"))
        #expect(!AnalysisProviderKeyFormat.isPlausible("key with spaces inside"))
        #expect(!AnalysisProviderKeyFormat.isPlausible("key\twith-a-tab"))
        #expect(!AnalysisProviderKeyFormat.isPlausible("clé-avec-accents-0123"))
        #expect(!AnalysisProviderKeyFormat.isPlausible("key-with-zero-width\u{200B}space"))
    }
}
