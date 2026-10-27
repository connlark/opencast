import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Model store layout")
struct ModelStoreLayoutTests {
    private static let names = [
        OpenCastModelContainerFactory.syncedConfigurationName,
        OpenCastModelContainerFactory.localConfigurationName
    ]

    @Test("Each store's two URLs end in Library/Application Support/N.store and the launch starts at the group URL")
    func urlsHaveThePinnedShape() {
        let layout = ModelStoreLayout.current()

        for (location, name) in zip([layout.synced, layout.local], Self.names) {
            #expect(location.configurationName == name)
            for url in [location.groupURL, location.appURL] {
                #expect(url.isFileURL)
                #expect(Array(url.pathComponents.suffix(3)) == ["Library", "Application Support", "\(name).store"])
            }
            #expect(Self.path(location.groupURL) != Self.path(location.appURL))
            #expect(location.resolvedURL == location.groupURL)
        }
        #expect(layout.localStoreURL == layout.local.groupURL)
    }

    @Test("The group URLs sit in the App Group container and the app URLs in the app's data container")
    func urlsSitInTheirContainers() throws {
        let layout = ModelStoreLayout.current()
        let groupContainer = try #require(Self.groupContainer)

        for (location, name) in zip([layout.synced, layout.local], Self.names) {
            #expect(Self.path(location.groupURL) == Self.path(groupContainer.appending(path: "Library/Application Support/\(name).store")))
            #expect(Self.path(location.appURL) == Self.path(URL.applicationSupportDirectory.appending(path: "\(name).store")))
            #expect(Self.path(location.appURL).hasPrefix(Self.path(Self.appContainer) + "/"))
            #expect(Self.path(location.groupURL).contains("/Containers/Shared/AppGroup/"))
            #expect(Self.path(location.appURL).contains("/Containers/Data/Application/"))
        }
    }

    /// The configurations `make` built before the layout existed, which
    /// resolved the App Group through `.automatic`: the group URL is the
    /// store every launch since f873d317 has opened.
    @Test("The group URLs are where the automatic group container put the stores")
    func groupURLsAreTheAutomaticLocations() {
        let layout = ModelStoreLayout.current()
        let synced = ModelConfiguration(
            OpenCastModelContainerFactory.syncedConfigurationName,
            schema: OpenCastModelContainerFactory.syncedSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(OpenCastModelContainerFactory.cloudKitContainerIdentifier)
        )
        let local = ModelConfiguration(
            OpenCastModelContainerFactory.localConfigurationName,
            schema: OpenCastModelContainerFactory.localSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        #expect(Self.path(layout.synced.groupURL) == Self.path(synced.url))
        #expect(Self.path(layout.local.groupURL) == Self.path(local.url))
    }

    /// What the pinned simulator cannot show: a directory created by the
    /// first computation on a fresh install, because both `Library/Application
    /// Support` directories already exist there. An empty directory left
    /// that way would be harmless: the relocation's branches turn on the
    /// `.store` file's presence, and an empty directory holds no leftovers.
    /// The inventories are taken right around the call, so the host app's
    /// own writes elsewhere stay out of the window; the store-name sweep
    /// skips the app container's `tmp`, where other suites build fixtures.
    @Test("Computing the layout adds no entry to either container's Library or Application Support, and no store file anywhere")
    func computingTheLayoutCreatesNothing() throws {
        let containers = [try #require(Self.groupContainer), Self.appContainer]
        let storeEntriesBefore = try containers.map(Self.storeNamedEntries(in:))
        let inventoriesBefore = try containers.map(Self.libraryInventory(in:))

        _ = ModelStoreLayout.current()

        let inventoriesAfter = try containers.map(Self.libraryInventory(in:))
        #expect(inventoriesAfter == inventoriesBefore)
        #expect(try containers.map(Self.storeNamedEntries(in:)) == storeEntriesBefore)
    }

    private static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ModelStoreLayout.appGroupIdentifier)
    }

    private static var appContainer: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    private static func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Every entry directly in `Library` and in `Library/Application Support`,
    /// by path relative to the container. A directory missing before the call
    /// lists nothing, so its creation shows as a new entry of its parent.
    private static func libraryInventory(in container: URL) throws -> Set<String> {
        var inventory: Set<String> = []
        for directory in ["Library", "Library/Application Support"] {
            let path = container.appending(path: directory).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                inventory.insert("\(directory)/\(name)")
            }
        }
        return inventory
    }

    /// Every path under the container with a store's name in it.
    private static func storeNamedEntries(in container: URL) throws -> Set<String> {
        let enumerator = try #require(FileManager.default.enumerator(atPath: container.path(percentEncoded: false)))
        var entries: Set<String> = []
        for case let relativePath as String in enumerator {
            if relativePath == "tmp" {
                enumerator.skipDescendants()
                continue
            }
            if names.contains(where: { relativePath.contains($0) }) {
                entries.insert(relativePath)
            }
        }
        return entries
    }
}
