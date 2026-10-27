import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Model container factory")
struct OpenCastModelContainerFactoryTests {
    private static let syncedName = OpenCastModelContainerFactory.syncedConfigurationName
    private static let localName = OpenCastModelContainerFactory.localConfigurationName

    @Test("On disk, each store opens at its own resolved URL, synced then local")
    func onDiskConfigurationsOpenAtTheResolvedURLs() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var layout = Self.layout(in: root)
        layout.synced.resolvedURL = layout.synced.appURL

        let configurations = OpenCastModelContainerFactory.configurations(
            inMemory: false,
            layout: layout,
            syncedCloudKitDatabase: .none
        )

        #expect(configurations.map(\.name) == [Self.syncedName, Self.localName])
        #expect(configurations.map(\.url) == [layout.synced.resolvedURL, layout.local.resolvedURL])
        #expect(configurations.map(\.isStoredInMemoryOnly) == [false, false])
        #expect(configurations.last?.url == layout.localStoreURL)
    }

    @Test("An on-disk open creates a missing Application Support and the stores land at the resolved URLs")
    func onDiskOpenCreatesTheMissingDirectory() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var layout = Self.layout(in: root)
        layout.synced.resolvedURL = layout.synced.appURL
        #expect(!Self.exists(root))

        try autoreleasepool {
            let container = try OpenCastModelContainerFactory.make(
                inMemory: false,
                layout: layout,
                syncedCloudKitDatabase: .none
            )
            let opened = Dictionary(
                uniqueKeysWithValues: container.configurations.map { ($0.name, $0.url.standardizedFileURL) }
            )
            #expect(opened == [
                Self.syncedName: layout.synced.resolvedURL.standardizedFileURL,
                Self.localName: layout.local.resolvedURL.standardizedFileURL
            ])
            #expect(opened[Self.localName] == layout.localStoreURL.standardizedFileURL)
        }

        #expect(Self.exists(layout.synced.appURL))
        #expect(Self.exists(layout.local.groupURL))
        #expect(!Self.exists(layout.synced.groupURL))
        #expect(!Self.exists(layout.local.appURL))
    }

    @Test("In memory, both configurations are memory-only and nothing reaches the layout's URLs")
    func inMemoryConfigurationsTouchNothing() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = Self.layout(in: root)

        let container = try OpenCastModelContainerFactory.make(inMemory: true, layout: layout)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: "https://example.com/factory-fixture.xml", title: "Factory Fixture"))
        try context.save()

        let memoryOnly = container.configurations.map(\.isStoredInMemoryOnly)
        #expect(memoryOnly == [true, true])
        #expect(!Self.exists(root))
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "OpenCastModelContainerFactoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Both stores at their group URLs, neither container directory created.
    private static func layout(in root: URL) -> ModelStoreLayout {
        ModelStoreLayout(synced: location(syncedName, in: root), local: location(localName, in: root))
    }

    private static func location(_ name: String, in root: URL) -> ModelStoreLocation {
        let groupURL = root.appending(path: "group/Library/Application Support/\(name).store")
        return ModelStoreLocation(
            configurationName: name,
            groupURL: groupURL,
            appURL: root.appending(path: "app/Library/Application Support/\(name).store"),
            resolvedURL: groupURL
        )
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
