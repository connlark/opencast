@testable import OpenCastAnalysis
import Testing

@Suite("Rust text semantics")
struct RustTextTests {
    @Test("Receipt tokens match the Rust token contract vectors")
    func tokenContract() {
        #expect(RustText.normalizedReceiptTokens("CAFÉ—İ Ⅳ ² don't .org.") == ["café", "i̇", "ⅳ", "²", "don", "t", "org"])
        #expect(RustText.normalizedReceiptTokens("Straße STRASSE σ ς ΟΣ İSTANBUL") == ["straße", "strasse", "σ", "ς", "οσ", "i̇stanbul"])
    }

    @Test("Token runs match by bytes, not canonical equivalence")
    func byteEquality() {
        let text = RustText.normalizedReceiptTokens("\u{AC00} offer now")
        let quote = RustText.normalizedReceiptTokens("\u{1100}\u{1161}")
        #expect(text.occurrences(of: quote).isEmpty)
        #expect(!text.containsRun(quote))
        #expect(text.occurrences(of: ["offer", "now"]) == [1])
    }

    @Test("Protocol strings compare by bytes")
    func protocolStrings() {
        #expect("MAX_TO\u{212A}ENS" == "MAX_TOKENS")
        #expect(!RustText.same("MAX_TO\u{212A}ENS", "MAX_TOKENS"))
        #expect(RustText.containsBytes("quota\u{301}", "quota"))
        #expect(!"quota\u{301}".contains("quota"))
    }

    @Test("Trim, blank and counts use White_Space and scalars")
    func trimming() {
        #expect(RustText.trim("\u{85}\u{3000} label \u{2029}") == "label")
        #expect(RustText.isBlank(" \u{A0}\t"))
        #expect(!RustText.isBlank("\u{200B}"))
        #expect(RustText.charCount("e\u{301}") == 2)
        #expect(RustText.whitespaceWordCount(" one  two\u{3000}three ") == 3)
    }

    @Test("Alphanumeric means Alphabetic or a number category")
    func alphanumeric() {
        #expect(RustText.isAlphanumeric("²"))
        #expect(RustText.isAlphanumeric("Ⅳ"))
        #expect(!RustText.isAlphanumeric("_"))
        #expect(!RustText.isAlphanumeric("-"))
    }
}
