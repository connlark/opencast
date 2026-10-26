import Foundation
@testable import OpenCastAnalysisProviders
import Testing

@Suite("Provider key")
struct AnalysisProviderKeyTests {
    @Test("The Keychain writer receives the trimmed key's bytes, and nothing prints them")
    func dataIsTheTrimmedKey() throws {
        let text = "  key-for-the-keychain-writer-0123  \n"
        let key = try #require(AnalysisProviderKey(text))
        #expect(key.withData { $0 } == Data("key-for-the-keychain-writer-0123".utf8))
        #expect(String(describing: key) == "AnalysisProviderKey(<redacted>)")
        #expect(!String(reflecting: key).contains("keychain-writer"))
        #expect(Mirror(reflecting: key).children.isEmpty)
    }

    @Test("Errors thrown by the writer pass through with their type")
    func writerErrorsPassThrough() throws {
        struct WriteFailed: Error, Equatable {}
        let key = try #require(AnalysisProviderKey("key-for-the-keychain-writer-0123"))
        #expect(throws: WriteFailed()) {
            try key.withData { (_: Data) throws(WriteFailed) in throw WriteFailed() }
        }
    }
}
