import OpenCastAnalysis
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key required presenter")
struct AnalysisKeyRequiredPresenterTests {
    @Test("Presenting makes a new request each time")
    func presentMakesNewRequests() throws {
        let presenter = AnalysisKeyRequiredPresenter()
        #expect(presenter.request == nil)

        presenter.present(feature: .chaptersSummary, trialStatus: .unitsLeft(2))
        let first = try #require(presenter.request)
        presenter.present(feature: .adDetection, trialStatus: .exhausted)
        let second = try #require(presenter.request)

        #expect(first.feature == .chaptersSummary)
        #expect(first.trialStatus == .unitsLeft(2))
        #expect(second.feature == .adDetection)
        #expect(second.id != first.id)
    }

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
