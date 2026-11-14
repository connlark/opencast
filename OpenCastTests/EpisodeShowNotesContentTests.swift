import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@Suite("Episode show notes content")
struct EpisodeShowNotesContentTests {
    private static let episodeID = "show-notes-episode"
    private static let notesWithList = """
    <p>In this episode we talk with a founder about the first five years.</p>\
    <p>Timestamps:</p>\
    <p>(00:00:00) Welcome and introductions<br>(00:04:12) Building the first prototype<br>\
    (00:17:45) Hiring the founding team<br>(00:41:30) Lessons for new founders</p>\
    <p>Thanks for listening.</p>
    """
    private static let notesWithoutList = """
    <p>A conversation about shipping software at 12:30 on a Friday.</p>\
    <p>(00:00:00) Welcome<br>(00:04:12) The prototype</p>
    """
    private static let summaryWithList = "0:00 Cold open\n2:15 The pitch\n9:40 The pivot"
    /// Notes shipped as escaped markup: every line reads as a literal `<p>`.
    private static let escapedNotes = """
    <p>&lt;p&gt;What we cover:&lt;/p&gt;</p><p>&lt;p&gt;0:00 Customers come first&lt;/p&gt;</p>\
    <p>&lt;p&gt;3:10 Research before spend&lt;/p&gt;</p><p>&lt;p&gt;12:45 Testing ideas cheaply&lt;/p&gt;</p>
    """
    private static let cleanSummary = """
    What we cover:
    0:00 Customers come first
    3:10 Research before spend
    12:45 Testing ideas cheaply
    """

    // MARK: - Which text is parsed

    @Test("Notes with a list give its chapters")
    func notesWithListGiveTheirChapters() {
        let chapters = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: "A founder story.",
            showNotesHTML: Self.notesWithList,
            duration: nil
        )

        #expect(chapters.map(\.startTime) == [0, 252, 1_065, 2_490])
        #expect(chapters.map(\.title) == [
            "Welcome and introductions",
            "Building the first prototype",
            "Hiring the founding team",
            "Lessons for new founders",
        ])
    }

    @Test("When the notes and the summary both hold a list, the notes win")
    func notesWinOverSummary() {
        let chapters = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.summaryWithList,
            showNotesHTML: Self.notesWithList,
            duration: nil
        )

        #expect(chapters.first?.title == "Welcome and introductions")
        #expect(chapters.count == 4)
    }

    @Test("Notes without a list fall back to the summary's")
    func notesWithoutListFallBackToSummary() {
        let chapters = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.summaryWithList,
            showNotesHTML: Self.notesWithoutList,
            duration: nil
        )

        #expect(chapters.map(\.title) == ["Cold open", "The pitch", "The pivot"])
        #expect(chapters.map(\.startTime) == [0, 135, 580])
    }

    @Test("Notes shipped as escaped markup fall back to a clean summary")
    func escapedNotesFallBackToCleanSummary() {
        #expect(EpisodeShowNotesContent.derivedChapters(summaryHTML: nil, showNotesHTML: Self.escapedNotes, duration: nil).isEmpty)

        let chapters = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.cleanSummary,
            showNotesHTML: Self.escapedNotes,
            duration: nil
        )

        #expect(chapters.map(\.title) == ["Customers come first", "Research before spend", "Testing ideas cheaply"])
        #expect(chapters.map(\.startTime) == [0, 190, 765])
    }

    @Test("With no notes at all, the summary's list")
    func noNotesUseTheSummary() {
        let chapters = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.summaryWithList,
            showNotesHTML: nil,
            duration: nil
        )

        #expect(chapters.map(\.title) == ["Cold open", "The pitch", "The pivot"])
    }

    @Test("Neither text holding a list gives none")
    func neitherTextGivesNone() {
        #expect(EpisodeShowNotesContent.derivedChapters(
            summaryHTML: "A founder story.",
            showNotesHTML: Self.notesWithoutList,
            duration: nil
        ).isEmpty)
        #expect(EpisodeShowNotesContent.derivedChapters(summaryHTML: nil, showNotesHTML: nil, duration: nil).isEmpty)
    }

    @Test("Notes that are the summary, as when a feed has no content:encoded, give their list or none")
    func notesThatAreTheSummary() {
        #expect(EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.notesWithList,
            showNotesHTML: Self.notesWithList,
            duration: nil
        ).map(\.startTime) == [0, 252, 1_065, 2_490])
        #expect(EpisodeShowNotesContent.derivedChapters(
            summaryHTML: Self.notesWithoutList,
            showNotesHTML: Self.notesWithoutList,
            duration: nil
        ).isEmpty)
    }

    @Test("The duration drops the entries past it")
    func durationBoundsTheList() async {
        let bounded = EpisodeShowNotesContent.derivedChapters(
            summaryHTML: nil,
            showNotesHTML: Self.notesWithList,
            duration: 1_800
        )
        #expect(bounded.map(\.startTime) == [0, 252, 1_065])

        let resolved = await EpisodeShowNotesContent.resolving(
            episodeID: Self.episodeID,
            summaryHTML: nil,
            showNotesHTML: Self.notesWithList,
            duration: 1_800
        )
        #expect(resolved.chapters(for: Self.episodeID).map(\.startTime) == [0, 252, 1_065])

        let offCaller = await EpisodeShowNotesContent.resolvingChapters(
            summaryHTML: nil,
            showNotesHTML: Self.notesWithList,
            duration: 1_800
        )
        #expect(offCaller == bounded)
    }

    // MARK: - Whose chapters

    @Test("Resolved content serves its chapters only for the episode it was resolved for")
    func chaptersBelongToTheirEpisode() async {
        let content = await EpisodeShowNotesContent.resolving(
            episodeID: Self.episodeID,
            summaryHTML: nil,
            showNotesHTML: Self.notesWithList,
            duration: nil
        )

        #expect(content.episodeID == Self.episodeID)
        #expect(!content.isEmpty)
        #expect(content.chapters(for: Self.episodeID).count == 4)
        #expect(content.chapters(for: "another-episode").isEmpty)
    }

    @Test("Empty content has no chapters for any episode")
    func emptyContentHasNoChapters() {
        #expect(EpisodeShowNotesContent.empty.chapters(for: Self.episodeID).isEmpty)
        #expect(EpisodeShowNotesContent.empty.chapters(for: "").isEmpty)
        #expect(EpisodeShowNotesContent.empty.episodeID == nil)
    }

    // MARK: - When the card renders

    /// Every input the episode screen gathers, all clear by default.
    struct RuleRow: CustomTestStringConvertible, Sendable {
        let name: String
        var resolvedFor = EpisodeShowNotesContentTests.episodeID
        var showNotesHTML = EpisodeShowNotesContentTests.notesWithList
        var displaysEmbeddedChapters = false
        var awaitsEmbeddedRead = false
        var publisherHasFinished = true
        var publisherHasChapters = false
        var rendersGeneratedChapters = false
        var awaitsGeneratedChapters = false
        var rendersCard = false

        var testDescription: String {
            name
        }
    }

    private static let ruleRows: [RuleRow] = [
        RuleRow(name: "all clear", rendersCard: true),
        RuleRow(name: "notes resolved for another episode", resolvedFor: "another-episode"),
        RuleRow(name: "notes with no list", showNotesHTML: notesWithoutList),
        RuleRow(name: "embedded chapters displayed", displaysEmbeddedChapters: true),
        RuleRow(name: "download's embedded read not landed", awaitsEmbeddedRead: true),
        RuleRow(name: "publisher not finished", publisherHasFinished: false),
        RuleRow(name: "publisher has chapters", publisherHasChapters: true),
        RuleRow(name: "generated chapters rendered", rendersGeneratedChapters: true),
        RuleRow(name: "completed analysis awaiting its section load", awaitsGeneratedChapters: true),
    ]

    @Test("The show-notes card renders only when every higher-ranked source has settled without chapters", arguments: ruleRows)
    func renderingRule(_ row: RuleRow) async {
        let content = await EpisodeShowNotesContent.resolving(
            episodeID: row.resolvedFor,
            summaryHTML: nil,
            showNotesHTML: row.showNotesHTML,
            duration: nil
        )

        let chapters = ShowNotesChaptersCardRule.chapters(
            from: content,
            episodeID: Self.episodeID,
            displaysEmbeddedChapters: row.displaysEmbeddedChapters,
            awaitsEmbeddedRead: row.awaitsEmbeddedRead,
            publisherHasFinished: row.publisherHasFinished,
            publisherHasChapters: row.publisherHasChapters,
            rendersGeneratedChapters: row.rendersGeneratedChapters,
            awaitsGeneratedChapters: row.awaitsGeneratedChapters
        )

        if row.rendersCard {
            #expect(chapters.map(\.title).first == "Welcome and introductions")
            #expect(chapters.count == 4)
        } else {
            #expect(chapters.isEmpty)
        }
    }
}
