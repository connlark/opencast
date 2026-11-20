import Testing
@testable import OpenCast

@MainActor
@Suite("AI Services free-tier copy")
struct AIServicesFreeTierCopyTests {
    private static let date = "January 1, 2027"
    private static let day = "November 7, 2026"

    @Test("The card footnote and the Settings mark")
    func cardFootnoteAndMark() {
        #expect(AIServicesCopy.freeTierCardFootnote == "Your Google key is on Google's free tier. Using opencast's trial service.")
        #expect(AIServicesCopy.freeTierMarkInHandoverWindow(day: Self.day, date: Self.date) == "On November 7, 2026, Google answered that your Google key is on its free tier, which is too limited for ad detection. Until January 1, 2027, opencast runs ad detection on its trial service instead when that service is available. To use your key, set up billing for its project in Google AI Studio.")
        #expect(AIServicesCopy.freeTierMark(day: Self.day) == "On November 7, 2026, Google answered that your Google key is on its free tier, which is too limited for ad detection. To use your key, set up billing for its project in Google AI Studio.")
    }
}
