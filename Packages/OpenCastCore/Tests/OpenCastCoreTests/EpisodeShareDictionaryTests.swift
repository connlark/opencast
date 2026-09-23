import CryptoKit
import Foundation
import OpenCastCore
import Testing

@Suite("Episode share dictionary")
struct EpisodeShareDictionaryTests {
    @Test("The v1 dictionary is frozen to its pinned bytes")
    func dictionaryMatchesPin() throws {
        let bytes = EpisodeShareDictionary.v1
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let fixture = try EpisodeShareTokenVectors.load()

        #expect(bytes.count == 965)
        #expect(fixture.dictionary.utf8Bytes == bytes.count)
        #expect(digest == EpisodeShareDictionary.v1SHA256)
        #expect(digest == fixture.dictionary.sha256)
    }

    @Test("The dictionary carries both dashes as UTF-8 and ends with the scheme")
    func dictionaryContentsSurviveEscaping() {
        let bytes = EpisodeShareDictionary.v1

        #expect(bytes.contains([0xE2, 0x80, 0x93]))
        #expect(bytes.contains([0xE2, 0x80, 0x94]))
        #expect(bytes.suffix(8) == Array("https://".utf8)[...])
    }
}
