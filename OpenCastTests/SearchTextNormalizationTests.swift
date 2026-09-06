import Foundation
import Testing
@testable import OpenCast

@Suite("Search token normalization")
struct SearchTextNormalizationTests {
    @Test("ASCII tokenization agrees with Unicode character classification")
    func asciiTokenizationPreservesWordBoundaries() {
        // Exercise every ASCII byte beside letters/digits, including control
        // characters and CRLF graphemes, against the native Unicode reference.
        for byte in UInt8(0)...UInt8(127) {
            let text = "AbC123" + String(decoding: [byte], as: UTF8.self) + "DeF456\r\nGHI"
            let expected = text.split { !$0.isLetter && !$0.isNumber }
                .map { String($0).lowercased() }
            #expect(SearchTextNormalization.searchTokens(in: text) == expected)
        }
    }

    @Test("Unicode words retain folding and grapheme boundaries")
    func unicodeTokenizationPreservesSearchSemantics() {
        #expect(SearchTextNormalization.searchTokens(in: "CAFÉ Cafe\u{301} IŞIK ışık ＡＢＣ１２３")
            == ["cafe", "cafe", "isik", "isik", "abc123"])
        #expect(SearchTextNormalization.searchTokens(in: "hello👩‍💻world 中文 ١٢٣")
            == ["hello", "world", "中文", "١٢٣"])
    }
}
