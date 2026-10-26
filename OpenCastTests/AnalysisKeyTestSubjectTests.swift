import Testing
@testable import OpenCast

@Suite("Analysis key test subject")
struct AnalysisKeyTestSubjectTests {
    private let whole = AnalysisKeyFixtures.googleText

    @Test("A whole typed key is tested, even when a key is saved")
    func typedWinsOverSaved() {
        #expect(AnalysisKeyTestSubject.choose(draft: whole, hasSavedKey: true) == .typed)
        #expect(AnalysisKeyTestSubject.choose(draft: whole, hasSavedKey: false) == .typed)
    }

    @Test("A typed fragment is never tested, and never falls back to the saved key")
    func fragmentTestsNothing() {
        #expect(AnalysisKeyTestSubject.choose(draft: "AIza", hasSavedKey: true) == .none)
        #expect(AnalysisKeyTestSubject.choose(draft: "two words", hasSavedKey: true) == .none)
    }

    @Test("With nothing typed, the saved key is tested when there is one")
    func emptyDraftTestsSaved() {
        #expect(AnalysisKeyTestSubject.choose(draft: "", hasSavedKey: true) == .saved)
        #expect(AnalysisKeyTestSubject.choose(draft: "  \n", hasSavedKey: true) == .saved)
        #expect(AnalysisKeyTestSubject.choose(draft: "", hasSavedKey: false) == .none)
    }
}
