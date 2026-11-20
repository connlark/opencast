import OpenCastAnalysis
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key required presenter")
struct AnalysisKeyRequiredPresenterTests {
    @Test("Dismissing clears only the request it names")
    func dismissClearsOnlyTheMatchingRequest() throws {
        let presenter = AnalysisKeyRequiredPresenter()
        presenter.present(feature: .adDetection, trialStatus: .exhausted)
        let stale = try #require(presenter.request)
        presenter.present(feature: .chaptersSummary, trialStatus: .exhausted)
        let current = try #require(presenter.request)

        presenter.dismiss(id: stale.id)
        #expect(presenter.request == current)

        presenter.dismiss(id: current.id)
        #expect(presenter.request == nil)
    }
}
