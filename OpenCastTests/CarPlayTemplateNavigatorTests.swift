import CarPlay
import Testing
@testable import OpenCast

@MainActor
struct CarPlayTemplateNavigatorTests {
    @Test(arguments: ["More Playlists", "More Episodes", "More Shows"], ["Up Next", "Current Show", "Inbox"])
    func fullBrowseStackStillOpensNowPlayingControls(page: String, destination: String) {
        let harness = CarPlayTemplateNavigationHarness(browseTitles: ["Playlists", page, "Episodes"])
        let originalStack = harness.stack
        let list = CPListTemplate(title: destination, sections: [])
        var succeeded: Bool?

        harness.navigator.pushNowPlayingList(list) { success, _ in succeeded = success }

        #expect(harness.stack.elementsEqual(originalStack, by: ===))
        #expect(harness.pendingCount == 1)
        harness.completeNext()
        #expect(harness.stack.elementsEqual(originalStack.prefix(3), by: ===))
        #expect(harness.pendingCount == 1)
        harness.completeNext()
        #expect(harness.stack.last === CPNowPlayingTemplate.shared)
        #expect(harness.stack.count == 4)
        harness.completeNext()

        #expect(succeeded == true)
        #expect(harness.stack.last === list)
        #expect(harness.maximumDepth == 5)
        #expect(harness.pendingCount == 0)
        harness.stack.removeLast()
        #expect(harness.stack.last === CPNowPlayingTemplate.shared)
    }

    @Test(arguments: 0...2)
    func shallowStacksKeepTheirEntireBrowseHistory(browseDepth: Int) {
        let harness = CarPlayTemplateNavigationHarness(browseTitles: (0..<browseDepth).map(String.init))
        let originalStack = harness.stack
        let list = CPListTemplate(title: "Up Next", sections: [])
        var succeeded: Bool?

        harness.navigator.pushNowPlayingList(list) { success, _ in succeeded = success }
        harness.completeNext()

        #expect(succeeded == true)
        #expect(harness.stack.dropLast().elementsEqual(originalStack, by: ===))
        #expect(harness.stack.last === list)
        #expect(harness.pendingCount == 0)
        #expect(harness.maximumDepth <= 5)
    }

    @Test(arguments: 0...2)
    func failuresStopTheSequenceAndReportTheError(failedOperation: Int) {
        let harness = CarPlayTemplateNavigationHarness(browseTitles: ["Playlists", "More Playlists", "Episodes"])
        let list = CPListTemplate(title: "Up Next", sections: [])
        var results: [Bool] = []
        var reportedError: (any Error)?
        harness.navigator.pushNowPlayingList(list) { success, error in
            results.append(success)
            reportedError = error
        }

        for _ in 0..<failedOperation { harness.completeNext() }
        harness.completeNext(succeeded: false)

        #expect(results == [false])
        #expect(reportedError != nil)
        #expect(harness.pendingCount == 0)
        #expect(!harness.stack.contains { $0 === list })
    }

    @Test(arguments: 0...2)
    func disconnectStopsPendingNavigation(completedOperations: Int) {
        let harness = CarPlayTemplateNavigationHarness(browseTitles: ["Playlists", "More Playlists", "Episodes"])
        let list = CPListTemplate(title: "Up Next", sections: [])
        var completionCount = 0
        harness.navigator.pushNowPlayingList(list) { _, _ in completionCount += 1 }
        for _ in 0..<completedOperations { harness.completeNext() }

        harness.navigator.invalidate()
        harness.completeNext()

        #expect(harness.pendingCount == 0)
        #expect(completionCount == 0)
        harness.navigator.pushNowPlayingList(list) { _, _ in completionCount += 1 }
        #expect(harness.pendingCount == 0)
    }

    @Test func repeatedControlTapDoesNotStartOverlappingNavigation() {
        let harness = CarPlayTemplateNavigationHarness(browseTitles: ["Playlists", "More Playlists", "Episodes"])
        let list = CPListTemplate(title: "Up Next", sections: [])
        var completionCount = 0
        for _ in 0..<2 {
            harness.navigator.pushNowPlayingList(list) { _, _ in completionCount += 1 }
        }
        #expect(harness.pendingCount == 1)
        for _ in 0..<3 { harness.completeNext() }
        #expect(completionCount == 1)
        #expect(harness.stack.count == 5)
    }
}
