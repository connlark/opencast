import Foundation
import Testing
@testable import OpenCast

@Suite("Search token normalization")
struct SearchTextNormalizationTests {
    @Test(
        "ASCII tokenization agrees with Unicode character classification",
        arguments: [
            ("AbC123 DeF456\r\nGHI", ["abc123", "def456", "ghi"]),
            ("/0 9: @A Z[ `a z{", ["0", "9", "a", "z", "a", "z"]),
            ("snake_case\u{0}tab\there", ["snake", "case", "tab", "here"]),
        ]
    )
    func asciiTokenizationPreservesWordBoundaries(text: String, expected: [String]) {
        #expect(SearchTextNormalization.searchTokens(in: text) == expected)
    }

    @Test("Unicode words retain folding and grapheme boundaries")
    func unicodeTokenizationPreservesSearchSemantics() {
        #expect(SearchTextNormalization.searchTokens(in: "CAFÉ Cafe\u{301} IŞIK ışık ＡＢＣ１２３")
            == ["cafe", "cafe", "isik", "isik", "abc123"])
        #expect(SearchTextNormalization.searchTokens(in: "hello👩‍💻world 中文 ١٢٣")
            == ["hello", "world", "中文", "١٢٣"])
    }
}
