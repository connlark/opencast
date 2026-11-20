import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Siri media user context")
struct SiriMediaUserContextTests {
    @Test("Initial empty context publishes once and a persisted load publishes its count")
    func initialAndPersistedCounts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: "https://example.com/one.xml", title: "One"))
        context.insert(SubscriptionRecord(feedURL: "https://example.com/two.xml", title: "Two"))
        try context.save()
        let fixture = makeFixture()

        #expect(await waitUntil { fixture.recorder.publishedCounts == [0] })
        await fixture.appModel.ensureCoreStoresLoaded(modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 2] })
    }

    private func makeFixture() -> (appModel: OpenCastAppModel, recorder: SiriMediaUserContextRecorder) {
        let recorder = SiriMediaUserContextRecorder()
        let discovery = SiriMediaDiscovery(
            userContextPublisher: { recorder.publishedCounts.append($0) },
            interactionDonator: { _ in },
            interactionGroupDeleter: { _ in }
        )
        let library = LibraryStore(
            feedService: SiriMediaUserContextFeedService(),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        return (
            OpenCastAppModel(
                library: library,
                allowsAutomaticFeedRefresh: false,
                siriMediaDiscovery: discovery
            ),
            recorder
        )
    }
}

@MainActor
private final class SiriMediaUserContextRecorder {
    var publishedCounts: [Int] = []
}

private actor SiriMediaUserContextFeedService: FeedService {
    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        throw SiriMediaUserContextFeedError.missingSnapshot
    }
}

private enum SiriMediaUserContextFeedError: Error {
    case missingSnapshot
}
