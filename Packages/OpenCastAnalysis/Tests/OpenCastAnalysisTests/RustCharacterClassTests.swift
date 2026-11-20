import Foundation
@testable import OpenCastAnalysis
import Testing

@Suite("Rust character classes")
struct RustCharacterClassTests {
    @Test("Alphanumeric, whitespace and lowercase match the services for every scalar")
    func everyScalar() throws {
        let fixture = try TestSupport.fixture("rust-char-classes.json")
        #expect(AnalysisReplay.characterClasses().sortedKeys() == fixture.sortedKeys())
    }
}
