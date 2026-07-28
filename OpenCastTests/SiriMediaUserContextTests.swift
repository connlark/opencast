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

    @Test("Subscribe, unsubscribe, and data reset publish changing counts")
    func subscriptionMutationsPublishCounts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/subscribe.xml"
        let fixture = makeFixture(
            feedSnapshots: [feedURL: feedSnapshot(feedURL: feedURL, title: "Subscribed Show")]
        )

        await fixture.appModel.ensureCoreStoresLoaded(modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0] })

        try await fixture.appModel.library.subscribe(to: feedURL, modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 1] })

        await fixture.appModel.unsubscribe(feedURL: feedURL, modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 1, 0] })

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Subscribed Show"))
        try context.save()
        _ = try fixture.appModel.library.reloadSyncedUserData(modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 1, 0, 1] })

        fixture.appModel.library.resetAfterDataNuke()
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 1, 0, 1, 0] })
    }

    @Test("Imported or CloudKit reloads republish only for a changed active set")
    func syncedReloadPublishesOnlyChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fixture = makeFixture()
        await fixture.appModel.ensureCoreStoresLoaded(modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0] })

        context.insert(SubscriptionRecord(feedURL: "https://example.com/imported.xml", title: "Imported"))
        try context.save()
        _ = try fixture.appModel.library.reloadSyncedUserData(modelContext: context)
        #expect(await waitUntil { fixture.recorder.publishedCounts == [0, 1] })

        _ = try fixture.appModel.library.reloadSyncedUserData(modelContext: context)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(fixture.recorder.publishedCounts == [0, 1])
    }

    private func makeFixture(
        feedSnapshots: [String: FeedSnapshot] = [:]
    ) -> (appModel: OpenCastAppModel, recorder: SiriMediaUserContextRecorder) {
        let recorder = SiriMediaUserContextRecorder()
        let discovery = SiriMediaDiscovery(
            userContextPublisher: { recorder.publishedCounts.append($0) },
            interactionDonator: { _ in },
            interactionGroupDeleter: { _ in }
        )
        let library = LibraryStore(
            feedService: SiriMediaUserContextFeedService(snapshots: feedSnapshots),
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

    private func feedSnapshot(feedURL: String, title: String) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: title
            ),
            episodes: []
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

@MainActor
private final class SiriMediaUserContextRecorder {
    var publishedCounts: [Int] = []
}

private actor SiriMediaUserContextFeedService: FeedService {
    let snapshots: [String: FeedSnapshot]

    init(snapshots: [String: FeedSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshots[url.absoluteString] else {
            throw SiriMediaUserContextFeedError.missingSnapshot
        }
        return snapshot
    }
}

private enum SiriMediaUserContextFeedError: Error {
    case missingSnapshot
}
