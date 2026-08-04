import Foundation
import Testing
@testable import OpenCast

struct EpisodeShowNotesBlockTests {
    @Test("Duplicate paragraphs receive distinct stable identities")
    func duplicateParagraphsAreDistinct() {
        let paragraph = AttributedString("Repeated paragraph")

        let blocks = EpisodeShowNotesBlock.identify([paragraph, paragraph])

        #expect(blocks[0].id != blocks[1].id)
        #expect(blocks.map(\.content) == [paragraph, paragraph])
    }

    @Test("Inserting a different paragraph preserves existing identities")
    func insertionPreservesExistingIdentities() {
        let first = AttributedString("First")
        let second = AttributedString("Second")
        let original = EpisodeShowNotesBlock.identify([first, second])
        let updated = EpisodeShowNotesBlock.identify([AttributedString("New"), first, second])

        #expect(Array(updated.dropFirst().map(\.id)) == original.map(\.id))
    }
}
