import Foundation
@testable import OpenCastAnalysis
import Testing

/// Every Unicode scalar must classify as the services classify it: the
/// fixture comes from the ad bridge's `char_classes` op (the receipt
/// tokenizer and `str::trim` themselves), so a drift in either side's
/// Unicode tables fails here.
@Suite("Rust character classes")
struct RustCharacterClassTests {
    @Test("Alphanumeric, whitespace and lowercase match the services for every scalar")
    func everyScalar() throws {
        let fixture = try TestSupport.fixture("rust-char-classes.json")
        #expect(AnalysisReplay.characterClasses().sortedKeys() == fixture.sortedKeys())
    }

    @Test("Private-use scalars are not alphanumeric")
    func privateUse() {
        #expect(!RustText.isAlphanumeric("\u{F882}"))
        #expect(RustText.normalizedReceiptTokens("\u{F882} offer now") == ["offer", "now"])
    }
}
