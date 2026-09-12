import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Help content store")
struct HelpContentStoreTests {
    private static let futureUpdatedAt = "2099-01-01T00:00:00Z"
    private static let pastUpdatedAt = "2000-01-01T00:00:00Z"

    @Test("The bundled document decodes with every help topic ID present")
    func bundledDocumentContainsEveryTopicID() throws {
        let harness = try Harness()

        #expect(harness.store.loadErrorMessage == nil)
        let ids = Set(harness.store.document.topics.map(\.id))
        for id in HelpTopicID.all {
            #expect(ids.contains(id), "Missing bundled help topic \(id)")
        }
        #expect(harness.store.visibleTopics.map(\.id) == harness.store.document.topics.map(\.id))
    }

    @Test("Unknown block types decode as unsupported and leave the other blocks intact")
    func unknownBlockTypeDecodesAsUnsupported() throws {
        let data = Self.documentData(
            updatedAt: Self.futureUpdatedAt,
            blocks: """
            {"type":"heading","text":"Heading"},
            {"type":"video","url":"https://support.opencast.mobile/clip"},
            {"type":"paragraph","text":"Body with **bold**"}
            """
        )

        let document = try HelpDocument.decode(data)

        let blocks = try #require(document.topics.first).identifiedBlocks.map(\.block)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .heading("Heading"))
        #expect(blocks[1] == .unsupported(type: "video"))
        guard case .paragraph(let text) = blocks[2] else {
            Issue.record("Expected a paragraph block, got \(blocks[2])")
            return
        }
        #expect(String(text.characters) == "Body with bold")
    }

    @Test("A throwing client keeps the document and records the error")
    func throwingClientKeepsDocument() async throws {
        let harness = try Harness(responses: [.failure(URLError(.notConnectedToInternet))])
        let bundledDocument = harness.store.document

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document == bundledDocument)
        #expect(harness.store.lastRefreshErrorMessage != nil)
        #expect(await harness.client.requestCount == 1)
    }

    @Test("Cancellation leaves the document and the error untouched")
    func cancellationLeavesStateUntouched() async throws {
        let harness = try Harness(responses: [.failure(CancellationError())])
        let bundledDocument = harness.store.document

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document == bundledDocument)
        #expect(harness.store.lastRefreshErrorMessage == nil)
    }

    @Test("A newer remote document replaces the bundled one and persists to the cache")
    func newerRemoteDocumentIsAdoptedAndPersisted() async throws {
        let harness = try Harness(responses: [.success(Self.documentData(updatedAt: Self.futureUpdatedAt))])

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document.updatedAt == Self.date(Self.futureUpdatedAt))
        #expect(harness.store.topic("remote-topic") != nil)
        #expect(harness.store.lastRefreshErrorMessage == nil)

        let reloaded = try Harness(isEnabled: false, cacheDirectory: harness.cacheDirectory)
        #expect(reloaded.store.document.updatedAt < Self.date(Self.futureUpdatedAt))
        await reloaded.store.refreshIfNeeded()
        #expect(reloaded.store.document.updatedAt == Self.date(Self.futureUpdatedAt))
        #expect(await reloaded.client.requestCount == 0)
    }

    @Test("An older remote document is ignored")
    func olderRemoteDocumentIsIgnored() async throws {
        let harness = try Harness(responses: [.success(Self.documentData(updatedAt: Self.pastUpdatedAt))])
        let bundledDocument = harness.store.document

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document == bundledDocument)
        #expect(harness.store.lastRefreshErrorMessage == nil)
    }

    @Test("A remote document with another schema version is ignored")
    func wrongSchemaVersionIsIgnored() async throws {
        let harness = try Harness(
            responses: [.success(Self.documentData(updatedAt: Self.futureUpdatedAt, schemaVersion: 2))]
        )
        let bundledDocument = harness.store.document

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document == bundledDocument)
    }

    @Test("A disabled configuration makes no requests")
    func disabledConfigurationMakesNoRequests() async throws {
        let harness = try Harness(
            responses: [.success(Self.documentData(updatedAt: Self.futureUpdatedAt))],
            isEnabled: false
        )
        let bundledDocument = harness.store.document

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document == bundledDocument)
        #expect(await harness.client.requestCount == 0)
    }

    @Test("Refreshes within an hour share one request")
    func refreshesWithinAnHourShareOneRequest() async throws {
        let harness = try Harness(
            responses: [
                .success(Self.documentData(updatedAt: Self.futureUpdatedAt)),
                .success(Self.documentData(updatedAt: Self.futureUpdatedAt)),
            ]
        )

        await harness.store.refreshIfNeeded()
        harness.clock.now += HelpContentStore.refreshInterval - 1
        await harness.store.refreshIfNeeded()
        #expect(await harness.client.requestCount == 1)

        harness.clock.now += 2
        await harness.store.refreshIfNeeded()
        #expect(await harness.client.requestCount == 2)
    }

    @Test("Topics above the current build are hidden but keep the document")
    func topicsAboveCurrentBuildAreHidden() async throws {
        let harness = try Harness(
            responses: [.success(Self.documentData(updatedAt: Self.futureUpdatedAt, minAppBuild: 2_000))],
            currentBuild: 1_000
        )

        await harness.store.refreshIfNeeded()

        #expect(harness.store.document.topics.contains { $0.id == "remote-topic" })
        #expect(harness.store.topic("remote-topic") == nil)
        #expect(!harness.store.visibleTopics.contains { $0.id == "remote-topic" })
    }

    private static func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private static func documentData(
        updatedAt: String,
        schemaVersion: Int = HelpDocument.supportedSchemaVersion,
        minAppBuild: Int? = nil,
        blocks: String = #"{"type":"paragraph","text":"Body"}"#
    ) -> Data {
        let minAppBuildField = minAppBuild.map { ",\"minAppBuild\":\($0)" } ?? ""
        return Data(
            """
            {"schemaVersion":\(schemaVersion),"updatedAt":"\(updatedAt)","topics":[{"id":"remote-topic","title":"Remote","symbol":"star","summary":"Remote summary","updatedAt":"\(updatedAt)"\(minAppBuildField),"related":[],"blocks":[\(blocks)]}]}
            """.utf8
        )
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private struct Harness {
    let client: HelpContentTestHTTPClient
    let store: HelpContentStore
    let cacheDirectory: URL
    let clock: TestClock

    init(
        responses: [HelpContentTestHTTPClient.Response] = [],
        isEnabled: Bool = true,
        currentBuild: Int = 1_000,
        cacheDirectory: URL? = nil
    ) throws {
        let directory = cacheDirectory ?? FileManager.default.temporaryDirectory.appending(
            path: "HelpContentStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = HelpContentTestHTTPClient(responses: responses)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_780_000_000))
        self.client = client
        self.clock = clock
        self.cacheDirectory = directory
        store = HelpContentStore(
            configuration: HelpContentBackendConfiguration(
                documentURL: URL(string: "https://support.opencast.mobile/app/help/v1.json")!,
                isEnabled: isEnabled
            ),
            httpClient: client,
            cacheDirectory: directory,
            currentBuild: currentBuild,
            now: { clock.now }
        )
    }
}
